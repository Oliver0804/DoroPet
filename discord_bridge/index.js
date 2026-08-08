// DoroPet ⇄ Discord 語音橋
//
// 為什麼要 sidecar:Discord 語音要 voice gateway + UDP + Opus 編解碼 + 加密,
// GDScript 這幾樣都沒有,硬做等於自己寫一個 GDExtension。這支程式負責 Discord 那一端,
// 跟 Godot 之間走 localhost WebSocket 傳 base64 wav。
//
// 收音:每個說話者是獨立的 opus 流(Discord 天生 per-user 分流),
//       停頓 SILENCE_MS 就當一句結束 → 轉 16k s16 mono wav → 送 Godot 做 STT。
// 播音:Godot 把 TTS wav 丟回來 → 排隊播進頻道。
//
// 環境變數:
//   DISCORD_BOT_TOKEN   必填
//   DORO_BRIDGE_PORT    WebSocket 埠(預設 8765)
//   DORO_BRIDGE_DEBUG   =1 時把每句收到的 wav 落盤到 debug/,不接 Godot 也能驗收音

import { Client, GatewayIntentBits, Events } from 'discord.js';
import {
	joinVoiceChannel, getVoiceConnection, EndBehaviorType,
	createAudioPlayer, createAudioResource, StreamType,
	AudioPlayerStatus, VoiceConnectionStatus, entersState,
	generateDependencyReport,
} from '@discordjs/voice';
import prism from 'prism-media';
import { pcmToWav, resampleTo16kMono, STT_RATE } from './audio.js';
import { WebSocketServer } from 'ws';
import { Readable } from 'node:stream';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const TOKEN = process.env.DISCORD_BOT_TOKEN || '';
const WS_PORT = Number(process.env.DORO_BRIDGE_PORT || 8765);
const DEBUG_DUMP = process.env.DORO_BRIDGE_DEBUG === '1';
// 由 Doro 自己啟動的(而不是你手動跑的)。這種進程沒人幫它收屍 ——
// Godot 若崩潰來不及 kill,它就變孤兒佔著埠。所以失聯太久就自己退出。
const AUTO_MODE = process.env.DORO_BRIDGE_AUTO === '1';
const AUTO_EXIT_MS = 90_000;

const SILENCE_MS = 800;          // 停頓多久算一句講完
// 比這短的當雜訊丟掉。實測 0.4 太寬鬆:呼吸聲、鍵盤聲、椅子聲都過得去,
// 送到 STT 換回一句「沒辨識到內容」,白花錢。0.8 擋掉絕大多數,
// 代價是「嗯」「對」這種極短回應會被吃掉 —— 但在熱詞閘門下那種話本來也不會觸發 Doro
const MIN_SPEECH_SEC = 0.8;
const MAX_SPEECH_SEC = 30;       // 保險:單句上限,避免有人開麥不放炸記憶體
// 實測 41% 的收音送到 STT 只換回「沒辨識到內容」—— 呼吸、鍵盤、椅子聲
// 都能撐過長度門檻。先量一下音量,近乎無聲的根本別送(省錢也省佇列)。
// 16-bit 音訊滿刻度 32767;正常說話 RMS 通常 >800,環境底噪多在 100 以下
const MIN_RMS = 350;

function log(...a) { console.log(new Date().toISOString().slice(11, 19), ...a); }

// 整段音訊的均方根音量。用來分辨「真的有人在講話」跟「麥克風開著而已」
function rmsOf(pcm) {
	const n = Math.floor(pcm.length / 2);
	if (n === 0) return 0;
	let sum = 0;
	for (let i = 0; i + 1 < pcm.length; i += 2) {
		const v = pcm.readInt16LE(i);
		sum += v * v;
	}
	return Math.sqrt(sum / n);
}

// ---------- Discord ----------
const client = new Client({
	intents: [GatewayIntentBits.Guilds, GatewayIntentBits.GuildVoiceStates],
});

let bridge = null;               // 目前的 WS 連線(Godot)
// 目前所在頻道與召喚者。Godot 可能中途重啟(它會自動重連),
// 而 joined 只在加入當下發一次 → 存起來,Godot 一連上就補發,
// 不然它會停在「不在頻道」狀態,TTS 就送不出去
let currentChannel = null;       // {guildId, channelId, invokerName, invokerId}
const activeSpeakers = new Map(); // userId -> true,防同一人重複 subscribe
let player = null;
const playQueue = [];
let playing = false;

function sendToGodot(obj) {
	if (!bridge || bridge.readyState !== 1) return false;
	bridge.send(JSON.stringify(obj));
	return true;
}

function attachReceiver(connection, guildId) {
	const receiver = connection.receiver;
	receiver.speaking.on('start', (userId) => {
		if (activeSpeakers.has(userId)) return;   // 講話期間會重複觸發
		activeSpeakers.set(userId, true);
		captureOne(receiver, userId, guildId).catch((e) => {
			log('收音失敗', userId, e.message);
		}).finally(() => activeSpeakers.delete(userId));
	});
	log('receiver 已掛上');
}

async function captureOne(receiver, userId, guildId) {
	const opusStream = receiver.subscribe(userId, {
		end: { behavior: EndBehaviorType.AfterSilence, duration: SILENCE_MS },
	});
	const decoder = new prism.opus.Decoder({ rate: 48000, channels: 2, frameSize: 960 });
	const chunks = [];
	let total = 0;
	const maxBytes = 48000 * 2 * 2 * MAX_SPEECH_SEC;

	await new Promise((resolve, reject) => {
		const pcm = opusStream.pipe(decoder);
		pcm.on('data', (d) => {
			if (total >= maxBytes) return;
			chunks.push(d);
			total += d.length;
		});
		pcm.on('end', resolve);
		pcm.on('error', reject);
		opusStream.on('error', reject);
	});

	const pcm48 = Buffer.concat(chunks);
	const sec = pcm48.length / (48000 * 2 * 2);
	if (sec < MIN_SPEECH_SEC) return;    // 太短,雜訊

	const rms = rmsOf(pcm48);
	if (rms < MIN_RMS) {
		log(`丟棄 ${userId} 的 ${sec.toFixed(1)}s(音量 RMS ${rms.toFixed(0)} < ${MIN_RMS},多半是環境音)`);
		return;
	}

	const pcm16 = await resampleTo16kMono(pcm48);
	const wav = pcmToWav(pcm16);

	// 說話者名字:給 LLM 當前綴,多人頻道裡才知道是誰在講
	let userName = userId;
	try {
		const guild = client.guilds.cache.get(guildId);
		const member = guild && await guild.members.fetch(userId);
		if (member) userName = member.displayName || member.user.username;
	} catch { /* 拿不到就用 id */ }

	if (DEBUG_DUMP) {
		const dir = path.join(HERE, 'debug');
		fs.mkdirSync(dir, { recursive: true });
		const f = path.join(dir, `${Date.now()}_${userName.replace(/[\/\\:*?"<>|\s]/g, '_')}.wav`);
		fs.writeFileSync(f, wav);
		log(`[debug] ${userName} ${sec.toFixed(1)}s → ${path.basename(f)}`);
	}

	const ok = sendToGodot({
		type: 'speech',
		user_id: userId,
		user_name: userName,
		duration_sec: Number(sec.toFixed(2)),
		wav_b64: wav.toString('base64'),
	});
	log(`收到 ${userName} 講話 ${sec.toFixed(1)}s${ok ? ' → 已送 Godot' : ' (Godot 未連線,丟棄)'}`);
}

function sendJoined() {
	if (!currentChannel) return;
	sendToGodot({
		type: 'joined',
		guild_id: currentChannel.guildId,
		channel_id: currentChannel.channelId,
		invoker_name: currentChannel.invokerName,
		invoker_id: currentChannel.invokerId,
	});
}

function ensurePlayer(connection) {
	if (player) return player;
	player = createAudioPlayer();
	player.on(AudioPlayerStatus.Idle, () => {
		playing = false;
		drainQueue();
	});
	player.on('error', (e) => {
		log('播放錯誤', e.message);
		playing = false;
		drainQueue();
	});
	connection.subscribe(player);
	return player;
}

// TTS 是一句一句串流過來的,AudioPlayer 一次只能吃一個資源 → 排隊播
function drainQueue() {
	if (playing || playQueue.length === 0 || !player) return;
	const wav = playQueue.shift();
	playing = true;
	const resource = createAudioResource(Readable.from(wav), {
		inputType: StreamType.Arbitrary,
	});
	player.play(resource);
	log(`播放 Doro 的聲音 ${wav.length} bytes(佇列剩 ${playQueue.length})`);
}

async function joinChannel(guildId, channelId, adapterCreator, invoker = null) {
	const existing = getVoiceConnection(guildId);
	if (existing) existing.destroy();
	player = null;
	playQueue.length = 0;
	playing = false;

	const connection = joinVoiceChannel({
		channelId, guildId, adapterCreator,
		selfDeaf: false,   // 預設是 true,不關掉就永遠收不到別人的聲音(而且不會報錯)
		selfMute: false,
	});
	await entersState(connection, VoiceConnectionStatus.Ready, 20_000);
	ensurePlayer(connection);
	attachReceiver(connection, guildId);
	currentChannel = {
		guildId, channelId,
		invokerName: invoker?.name || '',
		invokerId: invoker?.id || '',
	};
	sendJoined();
	log(`已加入語音頻道 ${channelId}`);
	return connection;
}

client.once(Events.ClientReady, async (c) => {
	log(`bot 上線:${c.user.tag}`);
	if (DEBUG_DUMP) log('DEBUG 模式:收到的每句話會存進 debug/');
	// Guild 層級註冊指令(全域註冊要等最多 1 小時才生效)
	const cmds = [
		{ name: 'doro', description: 'Doro 語音助手',
			options: [
				{ name: 'join', description: '把 Doro 拉進你所在的語音頻道', type: 1 },
				{ name: 'leave', description: '讓 Doro 離開語音頻道', type: 1 },
			] },
	];
	for (const guild of c.guilds.cache.values()) {
		try {
			await guild.commands.set(cmds);
			log(`已在 ${guild.name} 註冊 /doro 指令`);
		} catch (e) {
			log(`在 ${guild.name} 註冊指令失敗:${e.message}`);
		}
	}
});

client.on(Events.InteractionCreate, async (itr) => {
	if (!itr.isChatInputCommand() || itr.commandName !== 'doro') return;
	const sub = itr.options.getSubcommand();
	if (sub === 'leave') {
		const conn = getVoiceConnection(itr.guildId);
		if (conn) conn.destroy();
		currentChannel = null;
		sendToGodot({ type: 'left' });
		await itr.reply({ content: 'Doro 走了。', flags: 64 });
		return;
	}
	const ch = itr.member?.voice?.channel;
	if (!ch) {
		await itr.reply({ content: '你得先自己進一個語音頻道。', flags: 64 });
		return;
	}
	try {
		await joinChannel(ch.guild.id, ch.id, ch.guild.voiceAdapterCreator, {
			name: itr.member.displayName || itr.user.username,
			id: itr.user.id,
		});
		await itr.reply({ content: `Doro 進來了(${ch.name})。`, flags: 64 });
	} catch (e) {
		log('加入失敗', e.message);
		await itr.reply({ content: `進不去:${e.message}`, flags: 64 });
	}
});

// 已經在語音頻道時被人拖到別的頻道 → 跟著走
client.on(Events.VoiceStateUpdate, async (oldS, newS) => {
	if (newS.member?.id !== client.user?.id) return;
	if (!newS.channelId) {
		currentChannel = null;
		sendToGodot({ type: 'left' });
		log('被移出語音頻道');
		return;
	}
	if (oldS.channelId && oldS.channelId !== newS.channelId) {
		log(`被移動到 ${newS.channelId},跟著走`);
		try {
			await joinChannel(newS.guild.id, newS.channelId, newS.guild.voiceAdapterCreator,
				currentChannel ? { name: currentChannel.invokerName, id: currentChannel.invokerId } : null);
		} catch (e) {
			log('跟隨失敗', e.message);
		}
	}
});

// ---------- 孤兒自清 ----------
// 只在 AUTO_MODE 生效。手動啟動的 sidecar 不該因為你關掉 Doro 就消失。
let lastSeenGodot = Date.now();
if (AUTO_MODE) {
	setInterval(() => {
		if (bridge && bridge.readyState === 1) {
			lastSeenGodot = Date.now();
			return;
		}
		if (Date.now() - lastSeenGodot > AUTO_EXIT_MS) {
			log(`Doro 失聯超過 ${AUTO_EXIT_MS / 1000} 秒,自動退出(避免變孤兒進程)`);
			for (const g of client.guilds.cache.values()) getVoiceConnection(g.id)?.destroy();
			client.destroy();
			process.exit(0);
		}
	}, 5000).unref();
}

// ---------- 登入 ----------
// token 可能來自環境變數,也可能是 Godot 從設定視窗送過來的。
// sidecar 是獨立進程讀不到 Godot 的設定檔,所以走 WS 傳。
let loggedIn = false;
let loggingIn = false;

async function doLogin(token) {
	if (loggedIn) return { ok: true, bot: client.user?.tag || '' };
	if (loggingIn) return { ok: false, error: '正在登入中' };
	loggingIn = true;
	try {
		await client.login(token);
		loggedIn = true;
		return { ok: true, bot: client.user?.tag || '' };
	} catch (e) {
		return { ok: false, error: e.message };
	} finally {
		loggingIn = false;
	}
}

// ---------- WebSocket(給 Godot) ----------
// maxPayload:一句 30 秒的 16k mono wav base64 後約 1.3MB,8MB 綽綽有餘。
// 不設的話預設上限很大,異常輸入可能吃掉一堆記憶體
const wss = new WebSocketServer({ host: '127.0.0.1', port: WS_PORT, maxPayload: 8 * 1024 * 1024 });
wss.on('connection', (ws) => {
	if (bridge && bridge.readyState === 1) bridge.close();
	bridge = ws;
	lastSeenGodot = Date.now();
	log('Godot 已連線');
	ws.send(JSON.stringify({ type: 'ready', logged_in: loggedIn }));
	if (currentChannel) {
		sendJoined();   // Godot 重啟後補發,不然它不知道 bot 還在頻道裡
		log('補發頻道狀態給重連的 Godot');
	}
	ws.on('message', (raw) => {
		let msg;
		try { msg = JSON.parse(raw.toString()); } catch { return; }
		if (msg.type === 'login' && msg.token) {
			doLogin(msg.token).then((r) => {
				log(r.ok ? `登入成功:${r.bot}` : `登入失敗:${r.error}`);
				ws.send(JSON.stringify({ type: 'login_result', ...r }));
			});
		} else if (msg.type === 'speak' && msg.wav_b64) {
			playQueue.push(Buffer.from(msg.wav_b64, 'base64'));
			drainQueue();
		} else if (msg.type === 'stop') {
			playQueue.length = 0;
			if (player) player.stop();
		}
	});
	ws.on('close', () => {
		if (bridge === ws) bridge = null;
		log('Godot 斷線');
	});
	ws.on('error', (e) => log('WS 錯誤', e.message));
});

// ---------- 啟動 ----------
log(generateDependencyReport());
log(`WebSocket 等 Doro 連線:ws://127.0.0.1:${WS_PORT}`);
if (TOKEN) {
	doLogin(TOKEN).catch(() => {});
} else {
	// 沒有環境變數也照跑:token 可以從 Doro 的設定視窗填,連上後由 Godot 送過來
	log('沒有 DISCORD_BOT_TOKEN,等 Doro 送 token 過來(設定 → Discord 語音 → Bot Token)');
}

for (const sig of ['SIGINT', 'SIGTERM']) {
	process.on(sig, () => {
		log('關閉中...');
		for (const g of client.guilds.cache.values()) getVoiceConnection(g.id)?.destroy();
		client.destroy();
		wss.close();
		process.exit(0);
	});
}
