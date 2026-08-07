// 假 sidecar:不碰 Discord,只驗 Godot ⇄ sidecar 的 WebSocket 協定對不對。
// 搭配 _tmp_bridge_test.gd 一起跑。協定錯了在真實環境很難 debug(要有 bot、要有人講話),
// 所以先在這裡對完。
import { WebSocketServer } from 'ws';
import { pcmToWav } from './audio.js';

const PORT = 8766;
const got = { speak: 0, bytes: 0, stop: 0 };
let connected = false;

const wss = new WebSocketServer({ host: '127.0.0.1', port: PORT });
console.log(`假 sidecar 在 ws://127.0.0.1:${PORT} 等 Godot`);

wss.on('connection', (ws) => {
	connected = true;
	console.log('EVENT godot_connected');
	ws.send(JSON.stringify({ type: 'ready' }));

	setTimeout(() => {
		ws.send(JSON.stringify({ type: 'joined', guild_id: 'g1', channel_id: 'c1' }));
		console.log('SENT joined');
	}, 300);

	// 1 秒的 16k mono wav(內容是靜音,STT 會失敗,但這裡只驗傳輸與解碼)
	setTimeout(() => {
		const wav = pcmToWav(Buffer.alloc(16000 * 2));
		ws.send(JSON.stringify({
			type: 'speech', user_id: 'u1', user_name: '測試員',
			duration_sec: 1.0, wav_b64: wav.toString('base64'),
		}));
		console.log(`SENT speech (wav ${wav.length} bytes)`);
	}, 600);

	ws.on('message', (raw) => {
		let m;
		try { m = JSON.parse(raw.toString()); } catch { return; }
		if (m.type === 'speak') {
			const b = Buffer.from(m.wav_b64, 'base64');
			got.speak++;
			got.bytes += b.length;
			const hdrOk = b.toString('ascii', 0, 4) === 'RIFF';
			console.log(`GOT speak #${got.speak} ${b.length} bytes RIFF=${hdrOk}`);
		} else if (m.type === 'stop') {
			got.stop++;
			console.log('GOT stop');
		}
	});
});

setTimeout(() => {
	console.log('');
	const ok = connected && got.speak > 0 && got.stop > 0;
	console.log(`RESULT connected=${connected} speak=${got.speak} bytes=${got.bytes} stop=${got.stop}`);
	console.log(ok ? '結果: 協定對接成功' : '結果: 失敗');
	process.exit(ok ? 0 : 1);
}, 8000);
