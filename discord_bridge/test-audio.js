// 音訊管線判例。不需要 Discord token,`node test-audio.js` 直接跑。
// 驗的是「Discord 給的 48k stereo → STT 要的 16k mono wav」這條路對不對,
// 格式錯了 STT 會回空字串或亂碼,而且很難從 Godot 那端看出是這裡壞的。
import { pcmToWav, resampleTo16kMono, STT_RATE } from './audio.js';

let fail = 0;
function check(ok, desc) {
	if (!ok) fail++;
	console.log((ok ? '  PASS  ' : '  FAIL  ') + desc);
}

// 1 秒 440Hz 正弦波,48k stereo s16le —— 模擬 Discord 解碼後的樣子
function makeTone(seconds = 1.0) {
	const n = Math.round(48000 * seconds);
	const buf = Buffer.alloc(n * 2 * 2);   // stereo, 16-bit
	for (let i = 0; i < n; i++) {
		const v = Math.round(Math.sin((2 * Math.PI * 440 * i) / 48000) * 12000);
		buf.writeInt16LE(v, i * 4);        // L
		buf.writeInt16LE(v, i * 4 + 2);    // R
	}
	return buf;
}

const tone = makeTone(1.0);
console.log(`輸入: 48k stereo ${tone.length} bytes (1.0 秒)`);

const pcm16 = await resampleTo16kMono(tone);
const expected = STT_RATE * 2;   // 1 秒 × 16000 樣本 × 2 bytes
check(Math.abs(pcm16.length - expected) < expected * 0.02,
	`重採樣後長度 ${pcm16.length} bytes,預期約 ${expected}(誤差 <2%)`);

// 內容不能是靜音 —— ffmpeg 參數寫錯時最典型的症狀就是吐出一片 0
let peak = 0;
for (let i = 0; i + 1 < pcm16.length; i += 2) {
	peak = Math.max(peak, Math.abs(pcm16.readInt16LE(i)));
}
check(peak > 3000, `重採樣後有實際波形(peak=${peak},靜音的話 STT 會回空字串)`);

const wav = pcmToWav(pcm16);
check(wav.length === pcm16.length + 44, `WAV 總長 = PCM + 44 bytes header`);
check(wav.toString('ascii', 0, 4) === 'RIFF', 'header: RIFF');
check(wav.toString('ascii', 8, 12) === 'WAVE', 'header: WAVE');
check(wav.readUInt16LE(20) === 1, 'header: PCM 格式');
check(wav.readUInt16LE(22) === 1, 'header: mono');
check(wav.readUInt32LE(24) === STT_RATE, `header: ${STT_RATE} Hz`);
check(wav.readUInt16LE(34) === 16, 'header: 16-bit');
check(wav.readUInt32LE(4) === 36 + pcm16.length, 'header: RIFF chunk size 正確');
check(wav.readUInt32LE(40) === pcm16.length, 'header: data chunk size 正確');

// 太短的雜訊會被 index.js 的 MIN_SPEECH_SEC 擋掉,這裡確認長度算式一致
const shortPcm = makeTone(0.2);
const shortSec = shortPcm.length / (48000 * 2 * 2);
check(Math.abs(shortSec - 0.2) < 0.01, `時長算式正確(0.2 秒 → ${shortSec.toFixed(2)})`);

console.log('');
console.log(fail === 0 ? '結果: 全部通過' : `結果: 有 ${fail} 項失敗`);
process.exit(fail === 0 ? 0 : 1);
