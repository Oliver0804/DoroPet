// 音訊格式轉換。抽成獨立模組是為了能在沒有 Discord token 的情況下單獨測。
import { spawn } from 'node:child_process';

export const STT_RATE = 16000;   // byteplus_stt 要 16k s16 mono

// ffmpeg 輸出到 pipe 時 wav header 的長度欄位填不出正確值(串流當下還不知道總長),
// Godot 那邊解析會出問題 → 讓 ffmpeg 吐 raw s16le,長度確定後我們自己組 header
export function pcmToWav(pcm, rate = STT_RATE, channels = 1) {
	const h = Buffer.alloc(44);
	const byteRate = rate * channels * 2;
	h.write('RIFF', 0);
	h.writeUInt32LE(36 + pcm.length, 4);
	h.write('WAVE', 8);
	h.write('fmt ', 12);
	h.writeUInt32LE(16, 16);           // fmt chunk 大小
	h.writeUInt16LE(1, 20);            // PCM
	h.writeUInt16LE(channels, 22);
	h.writeUInt32LE(rate, 24);
	h.writeUInt32LE(byteRate, 28);
	h.writeUInt16LE(channels * 2, 32); // block align
	h.writeUInt16LE(16, 34);           // bits per sample
	h.write('data', 36);
	h.writeUInt32LE(pcm.length, 40);
	return Buffer.concat([h, pcm]);
}

// Discord 給 48k stereo,STT 要 16k mono。交給 ffmpeg 做
// (自己每 3 取 1 沒有低通濾波,會有 aliasing,STT 準確率會掉)
export function resampleTo16kMono(pcm48Stereo) {
	return new Promise((resolve, reject) => {
		const ff = spawn('ffmpeg', [
			'-hide_banner', '-loglevel', 'error',
			'-f', 's16le', '-ar', '48000', '-ac', '2', '-i', 'pipe:0',
			'-f', 's16le', '-ar', String(STT_RATE), '-ac', '1', 'pipe:1',
		]);
		const out = [];
		const err = [];
		ff.stdout.on('data', (d) => out.push(d));
		ff.stderr.on('data', (d) => err.push(d));
		ff.on('error', reject);
		ff.on('close', (code) => {
			if (code !== 0) return reject(new Error(`ffmpeg exit ${code}: ${Buffer.concat(err)}`));
			resolve(Buffer.concat(out));
		});
		ff.stdin.on('error', () => {});   // 對方先關就算了
		ff.stdin.end(pcm48Stereo);
	});
}
