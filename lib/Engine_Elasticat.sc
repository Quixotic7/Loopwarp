// Elasticat v2 foundation.
//
// One shared server-side transport phase drives one active mode synth at a time.
// Existing mode families are preserved under technically accurate names:
//   0 tape              former basic
//   1 tempo_varispeed   former classic
//   2 chopped
//   3 granular
//   4 random_ola        former wsola-style random overlap grains
//   5 pitch_corrected   former pv/PitchShift color
Engine_Elasticat : CroneEngine {

	var <transportSynth;
	var <activeSynth;
	var previewSynth;
	var <bufL;
	var <bufR;
	var <defaultBufL;
	var <defaultBufR;
	var <activeSliceSynths;
	var phaseBus;
	var scriptAddress;
	var statusResponder;
	var transportResponder;
	var modeSynthNames;
	var modeNames;
	var activeMode = 0;
	var playing = 0;
	var targetBpm = 120;
	var sampleSteps = 16;
	var loopStart = 0;
	var loopEnd = 128;
	var pitch = 0;
	var speed = 1;
	var direction = 1;
	var amp = 0.8;
	var pan = 0;
	var modeMacro = 0;
	var modeSwitchFade = 0.05;
	var loopXfade = 0.005;
	var maxCorrection = 0.02;
	var hardThreshold = 0.125;
	var correction = 0;
	var resetCount = 0;
	var loadGeneration = 0;
	var poolSize = 128;
	var poolBufL;
	var poolBufR;
	var poolPaths;
	var poolLoaded;
	var poolFrames;
	var poolRates;
	var poolGenerations;
	var sampleSlot = 1;
	var modeSwitchCount = 0;
	var failedModeSwitchCount = 0;
	var hardRealignCount = 0;
	var staleClockCount = 0;
	var lastClockSeq = -1;
	var lastPhase = 0;
	var lastExpectedPhase = 0;
	var lastPhaseError = 0;
	var lastErrorMs = 0;
	var derivedSourceBpm = 120;
	var sourceBpm = 120;
	var sourceFrames = 4;
	var sourceRate = 48000;
	var loaded = 0;
	var debugLevel = 1;
	var sliceAttack = 0.002;
	var sliceRelease = 0.02;
	var sliceMono = 0;
	var sliceSyncToClock = 1;
	var sliceRate = 1;
	var chopBeats = 0.25;
	var chopMode = 0;
	var chopAttack = 0.002;
	var chopHold = 0.04;
	var chopRelease = 0.01;
	var grainSize = 0.08;
	var grainOverlap = 8;
	var grainJitter = 0;
	var grainSpray = 0;
	var wsolaWindow = 0.1;
	var wsolaSearch = 0.03;
	var pvWindow = 0.2;
	var pvDispersion = 0;

	*new { arg context, doneCallback;
		^super.new(context, doneCallback);
	}

	alloc {
		var server;
		server = context.server;
		scriptAddress = NetAddr("localhost", 10111);
		modeSynthNames = [
			\elasticatTape,
			\elasticatTempoVarispeed,
			\elasticatChopped,
			\elasticatGranular,
			\elasticatRandomOla,
			\elasticatPitchCorrected
		];
		modeNames = [
			"tape",
			"tempo_varispeed",
			"chopped",
			"granular",
			"random_ola",
			"pitch_corrected"
		];

		phaseBus = Bus.audio(server, 1);
		bufL = Buffer.alloc(server, 4, 1);
		bufR = Buffer.alloc(server, 4, 1);
		defaultBufL = bufL;
		defaultBufR = bufR;
		poolBufL = Array.fill(poolSize, { nil });
		poolBufR = Array.fill(poolSize, { nil });
		poolPaths = Array.fill(poolSize, { "" });
		poolLoaded = Array.fill(poolSize, { 0 });
		poolFrames = Array.fill(poolSize, { 4 });
		poolRates = Array.fill(poolSize, { 48000 });
		poolGenerations = Array.fill(poolSize, { 0 });
		activeSliceSynths = Array.fill(32, { nil });

		this.addSynthDefs;
		server.sync;

		transportResponder = OSCFunc({
			arg msg;
			lastPhase = msg[3].asFloat;
			correction = msg[4].asFloat;
			if(debugLevel >= 3, {
				scriptAddress.sendBundle(0, [
					"/elasticat/transport",
					lastPhase,
					correction,
					msg[5].asFloat
				]);
			});
		}, path: '/elasticat/transportRaw', srcID: server.addr);

		statusResponder = OSCFunc({
			arg msg;
			lastPhase = msg[4].asFloat;
			scriptAddress.sendBundle(0, [
				"/elasticat/status",
				loaded,
				playing,
				modeNames.wrapAt(activeMode),
				msg[3].asFloat,
				msg[4].asFloat,
				msg[5].asFloat,
				msg[6].asFloat,
				msg[7].asFloat,
				targetBpm,
				derivedSourceBpm,
				correction,
				lastExpectedPhase,
				lastPhaseError,
				lastErrorMs,
				modeSwitchCount,
				failedModeSwitchCount,
				hardRealignCount,
				staleClockCount,
				loadGeneration
			]);
		}, path: '/elasticat/statusRaw', srcID: server.addr);

		transportSynth = Synth.new(\elasticatTransport, [
			\out, phaseBus.index,
			\playing, playing,
			\targetBpm, targetBpm,
			\loopBeats, this.activeLoopBeats,
			\correction, correction
		], context.xg);

		activeSynth = this.spawnMode(activeMode, 1);
		this.installCommands;
	}

	addSynthDefs {
		SynthDef(\elasticatTransport, {
			arg out=0, playing=0, targetBpm=120, loopBeats=4, resetTrig=0,
			resetPos=0, correction=0;
			var cyclesPerSecond, phase, run;

			run = Lag.kr(playing.clip(0, 1), 0.01);
			cyclesPerSecond = (targetBpm.max(1) / 60) / loopBeats.max(0.03125);
			phase = Phasor.ar(
				resetTrig,
				(cyclesPerSecond * (1 + correction.clip(-0.1, 0.1)) * run) / SampleRate.ir,
				0,
				1,
				resetPos.clip(0, 0.999999)
			);
			Out.ar(out, phase);
			SendReply.kr(Impulse.kr(1), cmdName: '/elasticat/transportRaw', values: [
				phase,
				correction,
				targetBpm
			]);
		}).add;

		// Sample preview: plays a slot's trim window at native rate, looping, with
		// no timestretch / pitch / warp -- the File-page audition. Independent of
		// the transport and mode synths.
		SynthDef(\elasticatPreview, {
			arg out=0, bufL=0, bufR=0, startFrac=0, endFrac=1, gain=1, gate=1;
			var frames, span, phase, pos, sig, env;
			frames = BufFrames.kr(bufL).max(4);
			span = (endFrac - startFrac).clip(0.0001, 1);
			phase = Phasor.ar(0, BufRateScale.kr(bufL) / (frames * span), 0, 1);
			pos = (startFrac + (phase * span)) * (frames - 1);
			sig = [
				BufRd.ar(1, bufL, pos, loop: 1, interpolation: 4),
				BufRd.ar(1, bufR, pos, loop: 1, interpolation: 4)
			];
			env = EnvGen.kr(Env.asr(0.005, 1, 0.02), gate, doneAction: 2);
			sig = sig * gain.max(0) * env;
			Out.ar(out, LeakDC.ar(sig));
		}).add;

		this.addDirectReaderDef(\elasticatTape, 0);
		this.addDirectReaderDef(\elasticatTempoVarispeed, 1);

		SynthDef(\elasticatChopped, {
			arg out=0, phaseBus=0, bufL=0, bufR=0, modeAmp=1, fadeTime=0.05,
			playing=0, resetTrig=0, resetPos=0,
			amp=0.8, pan=0, pitch=0, targetBpm=120, loopBeats=4, macro=0,
			startPoint=0, endPoint=128, chopBeats=0.25, chopMode=0, chopAttack=0.002, chopHold=0.04, chopRelease=0.01;
			var phase, frames, pos, trig, beatDur, duty, env, sig, modeGain, playGate, startNorm, range, readPhase;
			var pitchSmooth, sliceWidth, sliceStart, localPhase, forwardStop, loopForward, pingPong, pingPongPhase, stepRate, stopGate;
			phase = In.ar(phaseBus, 1);
			frames = BufFrames.kr(bufL).max(4);
			startNorm = Lag.kr(startPoint.clip(0, 127.99) / 128, 0.002);
			range = Lag.kr(((endPoint.clip(startPoint + 0.01, 128) - startPoint.clip(0, 127.99)) / 128).clip(0.0001, 1), 0.002);
			readPhase = (startNorm + (phase * range)).clip(0, 0.999999);
			beatDur = 60 / targetBpm.max(1);
			trig = Impulse.ar(((targetBpm.max(1) / 60) / chopBeats.max(0.03125)).max(0.1));
			pitchSmooth = Lag.kr(pitch, 0.03);
			sliceWidth = (range * (chopBeats.max(0.03125) / loopBeats.max(0.03125))).clip(0.0001, 1);
			sliceStart = Latch.ar(readPhase, trig);
			stepRate = (SampleRate.ir * BufRateScale.kr(bufL) * pitchSmooth.midiratio) / (frames * sliceWidth).max(1);
			localPhase = Sweep.ar(trig, stepRate) * playing.clip(0, 1);
			forwardStop = (sliceStart + (localPhase.clip(0, 1) * sliceWidth)).clip(0, 0.999999);
			loopForward = (sliceStart + (localPhase.wrap(0, 1) * sliceWidth)).clip(0, 0.999999);
			pingPongPhase = localPhase.wrap(0, 2).fold(0, 1);
			pingPong = (sliceStart + (pingPongPhase * sliceWidth)).clip(0, 0.999999);
			stopGate = (localPhase < 1);
			duty = (1 - (macro.clip(0, 1) * 0.85)).clip(0.05, 1);
			pos = Select.ar(chopMode.clip(0, 2), [forwardStop, loopForward, pingPong]) * (frames - 1);
			env = EnvGen.ar(Env.linen(
				chopAttack.max(0.0001),
				((chopBeats.max(0.03125) * beatDur * duty) - chopAttack - chopRelease).max(0.001),
				chopRelease.max(0.0001)
			), trig);
			sig = [
				BufRd.ar(1, bufL, pos, loop: 1, interpolation: 4),
				BufRd.ar(1, bufR, pos, loop: 1, interpolation: 4)
			] * env * Select.ar(chopMode.clip(0, 2), [stopGate, DC.ar(1), DC.ar(1)]);
			playGate = Lag.kr(playing.clip(0, 1), 0.01);
			modeGain = Lag.kr(modeAmp.clip(0, 1), fadeTime).sqrt;
			sig = Balance2.ar(sig[0], sig[1], pan.clip(-1, 1), amp.max(0) * modeGain * playGate);
			sig = LeakDC.ar(sig);
			SendReply.kr(Impulse.kr(30), cmdName: '/elasticat/statusRaw', values: [
				2, phase, frames, Amplitude.kr(sig[0]), Amplitude.kr(sig[1])
			]);
			Out.ar(out, sig);
		}).add;

		SynthDef(\elasticatGranular, {
			arg out=0, phaseBus=0, bufL=0, bufR=0, modeAmp=1, fadeTime=0.05,
			playing=0, resetTrig=0, resetPos=0,
			amp=0.8, pan=0, pitch=0, targetBpm=120, loopBeats=4, macro=0,
			startPoint=0, endPoint=128, grainSize=0.08, grainOverlap=8, grainJitter=0.0, grainSpray=0.0;
			var phase, frames, pos, dur, randomness, direct, wet, sig, modeGain, playGate, gainNorm, startNorm, range, readPhase, stepDur, overlap, overlapControl;
			phase = In.ar(phaseBus, 1);
			frames = BufFrames.kr(bufL).max(4);
			startNorm = Lag.kr(startPoint.clip(0, 127.99) / 128, 0.002);
			range = Lag.kr(((endPoint.clip(startPoint + 0.01, 128) - startPoint.clip(0, 127.99)) / 128).clip(0.0001, 1), 0.002);
			readPhase = (startNorm + (phase * range)).clip(0, 0.999999);
			pos = readPhase * (frames - 1);
			dur = Lag.kr(grainSize.clip(0.02, 0.5), 0.05);
			stepDur = 15 / targetBpm.max(1);
			overlapControl = Lag.kr(grainOverlap.clip(1, 64), 0.05);
			overlap = ((overlapControl * dur) / stepDur).clip(2, 32);
			randomness = Lag.kr((grainJitter + grainSpray + (macro * 0.03)).clip(0, 0.25), 0.05);
			direct = [
				BufRd.ar(1, bufL, pos, loop: 1, interpolation: 4),
				BufRd.ar(1, bufR, pos, loop: 1, interpolation: 4)
			];
			wet = [
				Warp1.ar(1, bufL, readPhase, Lag.kr(pitch, 0.03).midiratio, dur, -1, overlap, randomness, 4),
				Warp1.ar(1, bufR, readPhase, Lag.kr(pitch, 0.03).midiratio, dur, -1, overlap, randomness, 4)
			];
			sig = XFade2.ar(direct, wet, macro.linlin(0, 1, -0.75, 0.25));
			gainNorm = overlap.sqrt.reciprocal * 2.5 * (1 + (macro.clip(0, 1) * 0.25));
			playGate = Lag.kr(playing.clip(0, 1), 0.01);
			modeGain = Lag.kr(modeAmp.clip(0, 1), fadeTime).sqrt;
			sig = Balance2.ar(sig[0], sig[1], pan.clip(-1, 1), amp.max(0) * modeGain * gainNorm * playGate);
			sig = LeakDC.ar(sig);
			SendReply.kr(Impulse.kr(30), cmdName: '/elasticat/statusRaw', values: [
				3, phase, frames, Amplitude.kr(sig[0]), Amplitude.kr(sig[1])
			]);
			Out.ar(out, sig);
		}).add;

		SynthDef(\elasticatRandomOla, {
			arg out=0, phaseBus=0, bufL=0, bufR=0, modeAmp=1, fadeTime=0.05,
			playing=0, resetTrig=0, resetPos=0,
			amp=0.8, pan=0, pitch=0, targetBpm=120, loopBeats=4, macro=0,
			startPoint=0, endPoint=128, grainSize=0.1, grainOverlap=6, wander=0.03, timingJitter=0.0;
			var phase, frames, trig, dur, rate, chaos, pos, offset, direct, wet, sig, modeGain, playGate, gainNorm, startNorm, range, readPhase, stepDur, overlapControl, wanderControl;
			phase = In.ar(phaseBus, 1);
			frames = BufFrames.kr(bufL).max(4);
			startNorm = Lag.kr(startPoint.clip(0, 127.99) / 128, 0.002);
			range = Lag.kr(((endPoint.clip(startPoint + 0.01, 128) - startPoint.clip(0, 127.99)) / 128).clip(0.0001, 1), 0.002);
			readPhase = (startNorm + (phase * range)).clip(0, 0.999999);
			dur = Lag.kr(grainSize.clip(0.03, 0.6), 0.05);
			stepDur = 15 / targetBpm.max(1);
			overlapControl = Lag.kr(grainOverlap.clip(1, 64), 0.05);
			rate = (overlapControl / stepDur).clip(1, 240);
			trig = Impulse.ar(rate);
			chaos = macro.clip(0, 1);
			wanderControl = Lag.kr(wander.clip(0, 0.25), 0.05);
			offset = TRand.ar(wanderControl.neg, wanderControl, trig) * (0.25 + chaos);
			pos = ((readPhase * BufDur.kr(bufL)) + offset + (TRand.ar(timingJitter.neg, timingJitter, trig) * chaos)).wrap(0, BufDur.kr(bufL).max(0.001));
			direct = [
				BufRd.ar(1, bufL, readPhase * (frames - 1), loop: 1, interpolation: 4),
				BufRd.ar(1, bufR, readPhase * (frames - 1), loop: 1, interpolation: 4)
			];
			wet = [
				TGrains.ar(1, trig, bufL, Lag.kr(pitch, 0.03).midiratio, pos, dur, 0, 1, 4),
				TGrains.ar(1, trig, bufR, Lag.kr(pitch, 0.03).midiratio, pos, dur, 0, 1, 4)
			];
			sig = XFade2.ar(direct, wet, macro.linlin(0, 1, -0.75, 0.25));
			gainNorm = overlapControl.sqrt.reciprocal * 2.5;
			playGate = Lag.kr(playing.clip(0, 1), 0.01);
			modeGain = Lag.kr(modeAmp.clip(0, 1), fadeTime).sqrt;
			sig = Balance2.ar(sig[0], sig[1], pan.clip(-1, 1), amp.max(0) * modeGain * gainNorm * playGate);
			sig = LeakDC.ar(sig);
			SendReply.kr(Impulse.kr(30), cmdName: '/elasticat/statusRaw', values: [
				4, phase, frames, Amplitude.kr(sig[0]), Amplitude.kr(sig[1])
			]);
			Out.ar(out, sig);
		}).add;

		SynthDef(\elasticatPitchCorrected, {
			arg out=0, phaseBus=0, bufL=0, bufR=0, modeAmp=1, fadeTime=0.05,
			playing=0, resetTrig=0, resetPos=0,
			amp=0.8, pan=0, pitch=0, targetBpm=120, derivedSourceBpm=120, loopBeats=4,
			startPoint=0, endPoint=128, pvWindow=0.2, pvDispersion=0, pvTimeDispersion=0, macro=0;
			var phase, frames, pos, raw, shifted, ratio, sig, modeGain, playGate, window, startNorm, range, readPhase;
			phase = In.ar(phaseBus, 1);
			frames = BufFrames.kr(bufL).max(4);
			startNorm = Lag.kr(startPoint.clip(0, 127.99) / 128, 0.002);
			range = Lag.kr(((endPoint.clip(startPoint + 0.01, 128) - startPoint.clip(0, 127.99)) / 128).clip(0.0001, 1), 0.002);
			readPhase = (startNorm + (phase * range)).clip(0, 0.999999);
			pos = readPhase * (frames - 1);
			raw = [
				BufRd.ar(1, bufL, pos, loop: 1, interpolation: 4),
				BufRd.ar(1, bufR, pos, loop: 1, interpolation: 4)
			];
			ratio = (derivedSourceBpm.max(1) / targetBpm.max(1) * Lag.kr(pitch, 0.03).midiratio).clip(0.5, 2);
			window = Lag.kr(pvWindow.clip(0.005, 2), 0.05) * (1 + macro.clip(0, 1));
			shifted = PitchShift.ar(raw, window, ratio, Lag.kr(pvDispersion.clip(0, 1), 0.05), Lag.kr(pvTimeDispersion.clip(0, 1), 0.05));
			sig = shifted;
			playGate = Lag.kr(playing.clip(0, 1), 0.01);
			modeGain = Lag.kr(modeAmp.clip(0, 1), fadeTime).sqrt;
			sig = Balance2.ar(sig[0], sig[1], pan.clip(-1, 1), amp.max(0) * modeGain * playGate);
			sig = LeakDC.ar(sig);
			SendReply.kr(Impulse.kr(30), cmdName: '/elasticat/statusRaw', values: [
				5, phase, frames, Amplitude.kr(sig[0]), Amplitude.kr(sig[1])
			]);
			Out.ar(out, sig);
		}).add;

		SynthDef(\elasticatSliceVoice, {
			arg out=0, bufL=0, bufR=0,
			startPoint=0, endPoint=8, playMode=0, reverse=0,
			amp=0.8, pan=0, pitch=0, velocity=1, gate=1,
			sliceAttack=0.002, sliceRelease=0.02,
			lengthSeconds=0, syncToClock=1, sliceRate=1, warpMode=0,
			targetBpm=120, macro=0, grainSize=0.08, grainOverlap=8,
			grainJitter=0, wsolaWindow=0.1, wsolaSearch=0.03,
			pvWindow=0.2, pvDispersion=0;
			var frames, startFrame, endFrame, loFrame, hiFrame, continueMode, readLo, readHi, loopMode;
			var directionSign, resetFrame, rangeFrames, duration, pitchRatio, freePitchRatio, freeRate, fitRate, readRate;
			var pos, loopPos, sweepFrames, sweepForwardPos, sweepReversePos, sweepPos, readPhase, env, raw, grain, ola, pc, sig, playAmp;
			var grainDur, grainCount, grainRandom, olaTrig, olaPos, pcRatio;

			frames = BufFrames.kr(bufL).max(4);
			startFrame = (startPoint.clip(0, 127.99) / 128) * (frames - 1);
			endFrame = (endPoint.clip(0.01, 128) / 128) * (frames - 1);
			loFrame = startFrame.min(endFrame).clip(0, frames - 2);
			hiFrame = startFrame.max(endFrame).clip(loFrame + 1, frames - 1);
			continueMode = (playMode >= 3);
			loopMode = ((playMode >= 2) * (playMode < 3)).clip(0, 1);
			readLo = loFrame * (1 - continueMode);
			readHi = (hiFrame * (1 - continueMode)) + ((frames - 1) * continueMode);
			directionSign = 1 - (reverse.clip(0, 1) * 2);
			resetFrame = (startFrame * (1 - reverse.clip(0, 1))) + (endFrame * reverse.clip(0, 1));
			resetFrame = resetFrame.clip(readLo, readHi);
			rangeFrames = (readHi - readLo).max(1);
			duration = lengthSeconds.max(0.005);
			pitchRatio = Lag.kr(pitch, 0.01).midiratio.clip(0.03125, 32);
			freePitchRatio = Select.kr(warpMode >= 3, [pitchRatio, DC.kr(1)]);
			freeRate = BufRateScale.kr(bufL) * sliceRate.max(0.03125) * freePitchRatio;
			fitRate = rangeFrames / (duration * SampleRate.ir).max(1);
			readRate = Select.kr(syncToClock.clip(0, 1), [freeRate, fitRate]) * directionSign;
			loopPos = Phasor.ar(
				0,
				readRate,
				readLo,
				readHi.max(readLo + 1),
				resetFrame
			);
			sweepFrames = Sweep.ar(0, readRate.abs * SampleRate.ir);
			sweepForwardPos = resetFrame + sweepFrames;
			sweepReversePos = resetFrame - sweepFrames;
			sweepPos = Select.ar(reverse.clip(0, 1), [sweepForwardPos, sweepReversePos]);
			pos = Select.ar(loopMode, [sweepPos.clip(readLo, readHi), loopPos]);
			readPhase = (pos / (frames - 1)).clip(0, 0.999999);
			env = EnvGen.kr(
				Env.asr(sliceAttack.max(0.0001), 1, sliceRelease.max(0.0001), curve: -4),
				gate,
				doneAction: 2
			);
			raw = [
				BufRd.ar(1, bufL, pos, loop: 1, interpolation: 4),
				BufRd.ar(1, bufR, pos, loop: 1, interpolation: 4)
			];
			grainDur = Lag.kr(grainSize.clip(0.002, 0.5), 0.05);
			grainCount = Lag.kr(grainOverlap.clip(1, 64), 0.05);
			grainRandom = Lag.kr((grainJitter + (macro * 0.03)).clip(0, 0.25), 0.05);
			grain = [
				Warp1.ar(1, bufL, readPhase, pitchRatio, grainDur, -1, grainCount, grainRandom, 4),
				Warp1.ar(1, bufR, readPhase, pitchRatio, grainDur, -1, grainCount, grainRandom, 4)
			];
			olaTrig = Impulse.ar((grainCount / Lag.kr(wsolaWindow.clip(0.005, 0.5), 0.05)).clip(1, 240));
			olaPos = ((readPhase * BufDur.kr(bufL)) + TRand.ar(wsolaSearch.neg, wsolaSearch, olaTrig)).wrap(0, BufDur.kr(bufL).max(0.001));
			ola = [
				TGrains.ar(1, olaTrig, bufL, pitchRatio, olaPos, Lag.kr(wsolaWindow.clip(0.005, 0.5), 0.05), 0, 1, 4),
				TGrains.ar(1, olaTrig, bufR, pitchRatio, olaPos, Lag.kr(wsolaWindow.clip(0.005, 0.5), 0.05), 0, 1, 4)
			];
			pcRatio = pitchRatio;
			pc = PitchShift.ar(raw, Lag.kr(pvWindow.clip(0.005, 2), 0.05), pcRatio, Lag.kr(pvDispersion.clip(0, 1), 0.05), Lag.kr(pvDispersion.clip(0, 1), 0.05));
			sig = [
				Select.ar(warpMode.clip(0, 5), [raw[0], raw[0], raw[0], grain[0], ola[0], pc[0]]),
				Select.ar(warpMode.clip(0, 5), [raw[1], raw[1], raw[1], grain[1], ola[1], pc[1]])
			];
			playAmp = amp.max(0) * velocity.clip(0, 1) * env;
			sig = Balance2.ar(sig[0], sig[1], pan.clip(-1, 1), playAmp);
			sig = LeakDC.ar(sig);
			Out.ar(out, sig);
		}).add;
	}

	addDirectReaderDef { arg synthName, modeId;
		SynthDef(synthName, {
			arg out=0, phaseBus=0, bufL=0, bufR=0, modeAmp=1, fadeTime=0.05,
			playing=0, resetTrig=0, resetPos=0,
			amp=0.8, pan=0, pitch=0, speed=1, direction=1,
			targetBpm=120, derivedSourceBpm=120, loopBeats=4, startPoint=0, endPoint=128;
			var phase, frames, sourcePhase, pos, sig, modeGain, playGate, pitchRatio, startNorm, range, nativeIncrement;
			frames = BufFrames.kr(bufL).max(4);
			pitchRatio = Lag.kr(pitch, 0.03).midiratio.clip(0.03125, 32);
			startNorm = Lag.kr(startPoint.clip(0, 127.99) / 128, 0.002);
			range = Lag.kr(((endPoint.clip(startPoint + 0.01, 128) - startPoint.clip(0, 127.99)) / 128).clip(0.0001, 1), 0.002);
			if(modeId == 0, {
				nativeIncrement = (BufRateScale.kr(bufL) * speed.max(0.03125) * pitchRatio) / (frames * range).max(1);
				phase = Phasor.ar(resetTrig, nativeIncrement * playing.clip(0, 1), 0, 1, resetPos.clip(0, 0.999999));
			}, {
				phase = In.ar(phaseBus, 1);
			});
			sourcePhase = Select.ar(direction >= 0, [1 - phase, phase]);
			if(modeId == 0, {
				sourcePhase = sourcePhase.wrap(0, 1);
			}, {
				sourcePhase = sourcePhase.wrap(0, 1);
			});
			sourcePhase = (startNorm + (sourcePhase * range)).clip(0, 0.999999);
			pos = sourcePhase * (frames - 1);
			sig = [
				BufRd.ar(1, bufL, pos, loop: 1, interpolation: 4),
				BufRd.ar(1, bufR, pos, loop: 1, interpolation: 4)
			];
			playGate = Lag.kr(playing.clip(0, 1), 0.01);
			modeGain = Lag.kr(modeAmp.clip(0, 1), fadeTime).sqrt;
			sig = Balance2.ar(sig[0], sig[1], pan.clip(-1, 1), amp.max(0) * modeGain * playGate);
			sig = LeakDC.ar(sig);
			SendReply.kr(Impulse.kr(30), cmdName: '/elasticat/statusRaw', values: [
				modeId, phase, frames, Amplitude.kr(sig[0]), Amplitude.kr(sig[1])
			]);
			Out.ar(out, sig);
		}).add;
	}

	installCommands {
		this.addCommand(\loadSample, "s", { arg msg; this.loadSample(msg[1]); });
		this.addCommand(\loadPoolSlot, "is", { arg msg; this.loadPoolSlot(msg[1], msg[2]); });
		this.addCommand(\setSampleSlot, "i", { arg msg; this.setSampleSlot(msg[1]); });
		this.addCommand(\sampleSlot, "i", { arg msg; this.setSampleSlot(msg[1]); });
		this.addCommand(\previewSlot, "iffff", { arg msg; this.previewSlot(msg[1], msg[2], msg[3], msg[4], msg[5]); });
		this.addCommand(\play, "i", { arg msg; this.play(msg[1]); });
		this.addCommand(\pause, "", { this.play(0); });
		this.addCommand(\stopAndReset, "", { this.stopAndReset; });
		this.addCommand(\stop, "", { this.stopAndReset; });
		this.addCommand(\reset, "", { this.setPlayhead(0); });
		this.addCommand(\setMode, "i", { arg msg; this.setMode(msg[1]); });
		this.addCommand(\mode, "i", { arg msg; this.setMode(msg[1]); });
		this.addCommand(\setModeProfile, "i", { arg msg;
			scriptAddress.sendBundle(0, ["/elasticat/profile", msg[1].asInteger]);
		});
		this.addCommand(\setModeMacro, "f", { arg msg; modeMacro = msg[1].clip(0, 1); this.setActive(\macro, modeMacro); });
		this.addCommand(\setModeParam, "sf", { arg msg; this.setActive(msg[1].asSymbol, msg[2]); });
		this.addCommand(\setModeSwitchFade, "f", { arg msg; modeSwitchFade = msg[1].clip(0.001, 0.25); });
		this.addCommand(\setModeSwitchQuantization, "i", { arg msg;
			scriptAddress.sendBundle(0, ["/elasticat/switchQuantization", msg[1].asInteger]);
		});
		this.addCommand(\setSampleSteps, "f", { arg msg; this.setSampleSteps(msg[1]); });
		this.addCommand(\sampleSteps, "f", { arg msg; this.setSampleSteps(msg[1]); });
		this.addCommand(\setLoopBeats, "f", { arg msg; this.setSampleSteps(msg[1] * 4); });
		this.addCommand(\loopBeats, "f", { arg msg; this.setSampleSteps(msg[1] * 4); });
		this.addCommand(\setLoopPreview, "ff", { arg msg;
			scriptAddress.sendBundle(0, ["/elasticat/loopPreview", msg[1].clip(0, 1), msg[2].clip(0, 1)]);
		});
		this.addCommand(\commitLoop, "ff", { arg msg;
			scriptAddress.sendBundle(0, ["/elasticat/commitLoopPending", msg[1].clip(0, 1), msg[2].clip(0, 1)]);
		});
		this.addCommand(\setPitch, "f", { arg msg; pitch = msg[1].clip(-24, 24); this.setActive(\pitch, pitch); });
		this.addCommand(\pitch, "f", { arg msg; pitch = msg[1].clip(-24, 24); this.setActive(\pitch, pitch); });
		this.addCommand(\setSpeed, "f", { arg msg; speed = msg[1].clip(0.03125, 8); this.setActive(\speed, speed); });
		this.addCommand(\setReverse, "i", { arg msg; this.setReverse(msg[1]); });
		this.addCommand(\setDirection, "f", { arg msg;
			if(msg[1] < 0, { direction = -1; }, { direction = 1; });
			this.setActive(\direction, direction);
		});
		this.addCommand(\setAmp, "f", { arg msg; amp = msg[1].max(0); this.setActive(\amp, amp); });
		this.addCommand(\amp, "f", { arg msg; amp = msg[1].max(0); this.setActive(\amp, amp); });
		this.addCommand(\setPan, "f", { arg msg; pan = msg[1].clip(-1, 1); this.setActive(\pan, pan); });
		this.addCommand(\pan, "f", { arg msg; pan = msg[1].clip(-1, 1); this.setActive(\pan, pan); });
		this.addCommand(\syncClock, "ffi", { arg msg; this.syncClock(msg[1], msg[2], msg[3]); });
		this.addCommand(\setPlayhead, "f", { arg msg; this.setPlayhead(msg[1]); });
		this.addCommand(\playhead, "f", { arg msg; this.setPlayhead(msg[1]); });
		this.addCommand(\requestStatus, "", { this.sendStatus; });
		this.addCommand(\setDebug, "i", { arg msg; debugLevel = msg[1].asInteger.clip(0, 3); });

		this.addCommand(\sourceBpm, "f", { arg msg; this.setSourceBpm(msg[1]); });
		this.addCommand(\targetBpm, "f", { arg msg; targetBpm = msg[1].max(1); this.updateTransport; this.setActive(\targetBpm, targetBpm); });
		this.addCommand(\loopStart, "f", { arg msg; this.setLoopStart(msg[1]); });
		this.addCommand(\loopEnd, "f", { arg msg; this.setLoopEnd(msg[1]); });
		this.addCommand(\loopRegionPlayhead, "fff", { arg msg; this.setLoopRegionPlayhead(msg[1], msg[2], msg[3]); });
		this.addCommand(\xfade, "f", { arg msg; loopXfade = msg[1].clip(0, 0.25); });
		this.addCommand(\chopSteps, "f", { arg msg; chopBeats = msg[1].max(0.03125) / 4; this.setActive(\chopBeats, chopBeats); });
		this.addCommand(\chopBeats, "f", { arg msg; chopBeats = msg[1].max(0.03125); this.setActive(\chopBeats, chopBeats); });
		this.addCommand(\chopLoopMode, "i", { arg msg; chopMode = msg[1].asInteger.clip(0, 2); this.setActive(\chopMode, chopMode); });
		this.addCommand(\chopAttack, "f", { arg msg; chopAttack = msg[1].max(0.0001); this.setActive(\chopAttack, chopAttack); });
		this.addCommand(\chopHold, "f", { arg msg; chopHold = msg[1].max(0); this.setActive(\chopHold, chopHold); });
		this.addCommand(\chopRelease, "f", { arg msg; chopRelease = msg[1].max(0.0001); this.setActive(\chopRelease, chopRelease); });
		this.addCommand(\grainSize, "f", { arg msg; grainSize = msg[1].clip(0.002, 0.5); this.setActive(\grainSize, grainSize); });
		this.addCommand(\grainDensity, "f", { arg msg; grainOverlap = msg[1].clip(1, 64); this.setActive(\grainOverlap, grainOverlap); });
		this.addCommand(\grainJitter, "f", { arg msg; grainJitter = msg[1].clip(0, 0.25); grainSpray = grainJitter; this.setActive(\grainJitter, grainJitter); this.setActive(\grainSpray, grainSpray); });
		this.addCommand(\wsolaWindow, "f", { arg msg; wsolaWindow = msg[1].clip(0.005, 0.5); this.setActive(\grainSize, wsolaWindow); });
		this.addCommand(\wsolaSearch, "f", { arg msg; wsolaSearch = msg[1].clip(0, 0.1); this.setActive(\wander, wsolaSearch); });
		this.addCommand(\pvWindow, "f", { arg msg; pvWindow = msg[1].clip(0.005, 2); this.setActive(\pvWindow, pvWindow); });
		this.addCommand(\pvDispersion, "f", { arg msg; pvDispersion = msg[1].clip(0, 1); this.setActive(\pvDispersion, pvDispersion); });
		this.addCommand(\triggerSlice, "iffiifff", { arg msg; this.triggerSlice(msg[1], msg[2], msg[3], msg[4], msg[5], msg[6], msg[7], msg[8]); });
		this.addCommand(\releaseSlice, "i", { arg msg; this.releaseSlice(msg[1]); });
		this.addCommand(\releaseAllSlices, "", { this.releaseAllSlices; });
		this.addCommand(\sliceAttack, "f", { arg msg; sliceAttack = msg[1].clip(0.0001, 0.2); });
		this.addCommand(\sliceRelease, "f", { arg msg; sliceRelease = msg[1].clip(0.0001, 0.5); });
		this.addCommand(\setSliceMono, "i", { arg msg; sliceMono = msg[1].asInteger.clip(0, 1); });
		this.addCommand(\setSliceSyncToClock, "i", { arg msg; sliceSyncToClock = msg[1].asInteger.clip(0, 1); });
		this.addCommand(\setSliceRate, "f", { arg msg; sliceRate = msg[1].clip(0.03125, 16); });
	}

	spawnMode { arg modeIndex, startAmp;
		var synth;
		if(transportSynth.notNil, {
			synth = Synth.after(transportSynth, modeSynthNames.wrapAt(modeIndex.asInteger), this.commonArgs(startAmp));
		}, {
			synth = Synth.tail(context.xg, modeSynthNames.wrapAt(modeIndex.asInteger), this.commonArgs(startAmp));
		});
		^synth;
	}

	commonArgs { arg startAmp;
		^[
			\out, context.out_b.index,
			\phaseBus, phaseBus.index,
			\bufL, bufL.bufnum,
			\bufR, bufR.bufnum,
			\modeAmp, startAmp,
			\fadeTime, modeSwitchFade,
			\playing, playing,
			\resetTrig, resetCount,
			\resetPos, lastPhase,
			\amp, amp,
			\pan, pan,
			\pitch, pitch,
			\speed, speed,
			\direction, direction,
			\targetBpm, targetBpm,
			\derivedSourceBpm, derivedSourceBpm,
			\loopBeats, this.activeLoopBeats,
			\startPoint, loopStart,
			\endPoint, loopEnd,
			\macro, modeMacro
		];
	}

	setActive { arg key, value;
		if(activeSynth.notNil, {
			activeSynth.set(key, value);
		});
	}

	applyGlobals { arg synth;
		if(synth.notNil, {
			synth.set(
				\amp, amp,
				\pan, pan,
				\bufL, bufL.bufnum,
				\bufR, bufR.bufnum,
				\pitch, pitch,
				\speed, speed,
				\direction, direction,
				\playing, playing,
				\resetTrig, resetCount,
				\resetPos, lastPhase,
				\targetBpm, targetBpm,
				\derivedSourceBpm, derivedSourceBpm,
				\loopBeats, this.activeLoopBeats,
				\startPoint, loopStart,
				\endPoint, loopEnd,
				\macro, modeMacro,
				\fadeTime, modeSwitchFade
			);
		});
	}

	play { arg state;
		playing = state.asInteger.clip(0, 1);
		if(playing == 0, { this.releaseAllSlices; });
		this.updateTransport;
		this.setActive(\playing, playing);
		scriptAddress.sendBundle(0, ["/elasticat/play", playing]);
	}

	stopAndReset {
		this.play(0);
		this.releaseAllSlices;
		this.setPlayhead(0);
	}

	setReverse { arg value;
		if(value.asInteger == 1, {
			direction = -1;
		}, {
			direction = 1;
		});
		this.setActive(\direction, direction);
	}

	triggerSlice { arg sliceIndex, startPoint, endPoint, playMode, reverse, velocity, lengthSeconds, notePitch;
		var idx, startPos, endPos, mode, rev, pitchValue, pitchRatio, duration, sliceRatio, synth;
		idx = sliceIndex.asInteger.clip(1, 32);
		startPos = startPoint.asFloat.clip(0, 127.99);
		endPos = endPoint.asFloat.clip(0.01, 128);
		if(endPos <= startPos, { endPos = (startPos + 0.01).clip(0.01, 128); });
		mode = playMode.asInteger.clip(0, 3);
		rev = reverse.asInteger.clip(0, 1);
		pitchValue = notePitch.asFloat.clip(-48, 48);
		pitchRatio = pitchValue.midiratio.max(0.001);
		duration = lengthSeconds.asFloat;

		if(duration <= 0, {
			if(mode >= 2, {
				duration = 60;
			}, {
				sliceRatio = ((endPos - startPos).abs / 128).max(0.0001);
				duration = ((sourceFrames.max(1) * sliceRatio) / sourceRate.max(1)) / pitchRatio;
			});
		});
		duration = duration.clip(0.005, 60);

		if(sliceMono == 1, { this.releaseAllSlices; });
		if(activeSliceSynths.notNil and: { activeSliceSynths[idx - 1].notNil }, {
			activeSliceSynths[idx - 1].set(\gate, 0);
		});

		synth = Synth.tail(context.xg, \elasticatSliceVoice, [
			\out, context.out_b.index,
			\bufL, bufL.bufnum,
			\bufR, bufR.bufnum,
			\startPoint, startPos,
			\endPoint, endPos,
			\playMode, mode,
			\reverse, rev,
			\amp, amp,
			\pan, pan,
			\pitch, pitchValue,
			\velocity, velocity.asFloat.clip(0, 1),
			\sliceAttack, sliceAttack,
			\sliceRelease, sliceRelease,
			\lengthSeconds, duration,
			\syncToClock, sliceSyncToClock,
			\sliceRate, sliceRate,
			\warpMode, activeMode,
			\targetBpm, targetBpm,
			\macro, modeMacro,
			\grainSize, grainSize,
			\grainOverlap, grainOverlap,
			\grainJitter, grainJitter + grainSpray,
			\wsolaWindow, wsolaWindow,
			\wsolaSearch, wsolaSearch,
			\pvWindow, pvWindow,
			\pvDispersion, pvDispersion,
			\gate, 1
		]);
		if(activeSliceSynths.notNil, { activeSliceSynths[idx - 1] = synth; });
		Routine({
			duration.wait;
			if(synth.notNil, { synth.set(\gate, 0); });
			if(activeSliceSynths.notNil and: { activeSliceSynths[idx - 1] == synth }, {
				activeSliceSynths[idx - 1] = nil;
			});
		}).play(SystemClock);
	}

	releaseSlice { arg sliceIndex;
		var idx;
		idx = sliceIndex.asInteger.clip(1, 32);
		if(activeSliceSynths.notNil and: { activeSliceSynths[idx - 1].notNil }, {
			activeSliceSynths[idx - 1].set(\gate, 0);
			activeSliceSynths[idx - 1] = nil;
		});
	}

	releaseAllSlices {
		if(activeSliceSynths.notNil, {
			activeSliceSynths.do({ arg synth, i;
				if(synth.notNil, {
					synth.set(\gate, 0);
					activeSliceSynths[i] = nil;
				});
			});
		});
	}

	activeLoopBeats {
		var region;
		region = ((loopEnd - loopStart).max(0.01) / 128).clip(0.0001, 1);
		^((sampleSteps.max(1) / 4) * region).max(0.03125);
	}

	setSampleSteps { arg steps;
		sampleSteps = steps.clip(1, 512);
		this.recalculateNativeTempo;
		this.updateTransport;
		this.setActive(\loopBeats, this.activeLoopBeats);
	}

	setSourceBpm { arg bpm;
		sourceBpm = bpm.max(1);
		derivedSourceBpm = sourceBpm;
		this.setActive(\derivedSourceBpm, derivedSourceBpm);
	}

	setLoopStart { arg position;
		loopStart = position.clip(0, 127.99);
		if(loopEnd <= loopStart, { loopEnd = (loopStart + 0.01).clip(0.01, 128); });
		this.updateTransport;
		this.setActive(\loopBeats, this.activeLoopBeats);
		this.setActive(\startPoint, loopStart);
		this.setActive(\endPoint, loopEnd);
	}

	setLoopEnd { arg position;
		loopEnd = position.clip(0.01, 128);
		if(loopEnd <= loopStart, { loopStart = (loopEnd - 0.01).clip(0, 127.99); });
		this.updateTransport;
		this.setActive(\loopBeats, this.activeLoopBeats);
		this.setActive(\startPoint, loopStart);
		this.setActive(\endPoint, loopEnd);
	}

	setLoopRegionPlayhead { arg startPosition, endPosition, phase;
		loopStart = startPosition.clip(0, 127.99);
		loopEnd = endPosition.clip(0.01, 128);
		if(loopEnd <= loopStart, { loopEnd = (loopStart + 0.01).clip(0.01, 128); });
		resetCount = resetCount + 1;
		lastPhase = phase.wrap(0, 1);
		if(transportSynth.notNil, {
			transportSynth.set(
				\playing, playing,
				\targetBpm, targetBpm,
				\loopBeats, this.activeLoopBeats,
				\correction, correction,
				\resetPos, lastPhase,
				\resetTrig, resetCount
			);
		});
		if(activeSynth.notNil, {
			activeSynth.set(
				\playing, playing,
				\targetBpm, targetBpm,
				\loopBeats, this.activeLoopBeats,
				\startPoint, loopStart,
				\endPoint, loopEnd,
				\resetPos, lastPhase,
				\resetTrig, resetCount
			);
		});
		scriptAddress.sendBundle(0, ["/elasticat/reset", lastPhase]);
	}

	updateTransport {
		if(transportSynth.notNil, {
			transportSynth.set(
				\playing, playing,
				\targetBpm, targetBpm,
				\loopBeats, this.activeLoopBeats,
				\correction, correction
			);
		});
		this.setActive(\playing, playing);
		this.setActive(\targetBpm, targetBpm);
		this.setActive(\loopBeats, this.activeLoopBeats);
	}

	setPlayhead { arg phase;
		resetCount = resetCount + 1;
		lastPhase = phase.wrap(0, 1);
		if(transportSynth.notNil, {
			transportSynth.set(\resetPos, lastPhase, \resetTrig, resetCount);
		});
		this.setActive(\resetPos, lastPhase);
		this.setActive(\resetTrig, resetCount);
		scriptAddress.sendBundle(0, ["/elasticat/reset", lastPhase]);
	}

	setMode { arg modeIndex;
		var newMode, oldMode, oldSynth, newSynth;
		newMode = modeIndex.asInteger.clip(0, modeSynthNames.size - 1);
		if(newMode == activeMode and: { activeSynth.notNil }, {
			^nil;
		});

		oldMode = activeMode;
		oldSynth = activeSynth;
		if(oldMode == 0 and: { newMode != 0 }, {
			this.setPlayhead(lastPhase);
		});
		activeMode = newMode;
		newSynth = this.spawnMode(activeMode, 0);
		this.applyGlobals(newSynth);
		activeSynth = newSynth;
		activeSynth.set(\modeAmp, 1, \fadeTime, modeSwitchFade);

		if(oldSynth.notNil, {
			oldSynth.set(\modeAmp, 0, \fadeTime, modeSwitchFade);
			Routine({
				modeSwitchFade.wait;
				oldSynth.free;
			}).play(SystemClock);
		});

		modeSwitchCount = modeSwitchCount + 1;
		scriptAddress.sendBundle(0, ["/elasticat/mode", modeNames.wrapAt(activeMode), activeMode, modeSwitchCount]);
	}

	syncClock { arg expectedPhase, tempo, sequence;
		var err, absMs, loopSeconds;
		if(sequence <= lastClockSeq, {
			staleClockCount = staleClockCount + 1;
			^nil;
		});
		lastClockSeq = sequence;
		targetBpm = tempo.max(1);
		lastExpectedPhase = expectedPhase.wrap(0, 1);
		err = lastExpectedPhase - lastPhase;
		if(err > 0.5, { err = err - 1; });
		if(err < -0.5, { err = err + 1; });
		loopSeconds = this.activeLoopBeats * 60 / targetBpm;
		absMs = err.abs * loopSeconds * 1000;
		lastPhaseError = err;
		lastErrorMs = absMs;

		if(err.abs > hardThreshold, {
			correction = 0;
			hardRealignCount = hardRealignCount + 1;
			this.setPlayhead(lastExpectedPhase);
		}, {
			if(absMs < 0.5, {
				correction = 0;
			}, {
				correction = (err * 0.5).clip(maxCorrection.neg, maxCorrection);
			});
		});

		this.updateTransport;
		this.setActive(\targetBpm, targetBpm);
		this.setActive(\loopBeats, this.activeLoopBeats);
	}

	loadSample { arg path;
		this.loadPoolSlot(sampleSlot, path);
	}

	loadPoolSlot { arg slot, path;
		var sf, channels, frames, rate, generation, idx;
		if(path.isNil, { ^nil; });
		slot = slot.asInteger.clip(1, poolSize);
		idx = slot - 1;
		path = path.asString;
		loadGeneration = loadGeneration + 1;
		generation = loadGeneration;
		poolGenerations[idx] = generation;
		scriptAddress.sendBundle(0, ["/elasticat/pool/load/request", slot, path, generation]);
		if(slot == sampleSlot, {
			scriptAddress.sendBundle(0, ["/elasticat/load/request", path, generation]);
		});

		sf = SoundFile.openRead(path);
		if(sf.isNil, {
			scriptAddress.sendBundle(0, ["/elasticat/pool/load/failed", slot, path, generation]);
			if(slot == sampleSlot, {
				scriptAddress.sendBundle(0, ["/elasticat/load/failed", path, generation]);
			});
			^nil;
		});
		channels = sf.numChannels;
		frames = sf.numFrames;
		rate = sf.sampleRate;
		sf.close;
		scriptAddress.sendBundle(0, ["/elasticat/pool/load/opened", slot, path, channels, frames, rate, generation]);
		if(slot == sampleSlot, {
			scriptAddress.sendBundle(0, ["/elasticat/load/opened", path, channels, frames, rate, generation]);
		});

		Buffer.readChannel(server: context.server, path: path, startFrame: 0, numFrames: -1, channels: [0], action: {
			arg newL;
			if(generation != poolGenerations[idx], {
				newL.free;
				staleClockCount = staleClockCount + 1;
			}, {
				if(newL.numFrames <= 0, {
					newL.free;
					scriptAddress.sendBundle(0, ["/elasticat/pool/load/failed", slot, path, generation]);
					if(slot == sampleSlot, {
						scriptAddress.sendBundle(0, ["/elasticat/load/failed", path, generation]);
					});
				}, {
					scriptAddress.sendBundle(0, ["/elasticat/pool/load/readDone", slot, 0, newL.numFrames, newL.numChannels, generation]);
					if(slot == sampleSlot, {
						scriptAddress.sendBundle(0, ["/elasticat/load/readDone", 0, newL.numFrames, newL.numChannels, generation]);
					});
					if(channels > 1, {
						Buffer.readChannel(server: context.server, path: path, startFrame: 0, numFrames: -1, channels: [1], action: {
							arg newR;
							if(generation != poolGenerations[idx], {
								newL.free;
								newR.free;
							}, {
								scriptAddress.sendBundle(0, ["/elasticat/pool/load/readDone", slot, 1, newR.numFrames, newR.numChannels, generation]);
								if(slot == sampleSlot, {
									scriptAddress.sendBundle(0, ["/elasticat/load/readDone", 1, newR.numFrames, newR.numChannels, generation]);
								});
								this.installPoolBuffers(slot, newL, newR, path, frames, rate, generation);
							});
						});
					}, {
						this.installPoolBuffers(slot, newL, newL, path, frames, rate, generation);
					});
				});
			});
		});
	}

	installPoolBuffers { arg slot, newL, newR, path, frames, rate, generation;
		var idx, oldL, oldR;
		slot = slot.asInteger.clip(1, poolSize);
		idx = slot - 1;
		if(generation != poolGenerations[idx], {
			newL.free;
			if(newR != newL, { newR.free; });
			^nil;
		});

		oldL = poolBufL[idx];
		oldR = poolBufR[idx];
		poolBufL[idx] = newL;
		poolBufR[idx] = newR;
		poolPaths[idx] = path;
		poolLoaded[idx] = 1;
		poolFrames[idx] = frames;
		poolRates[idx] = rate;

		if(slot == sampleSlot, {
			this.setSampleSlot(slot);
			scriptAddress.sendBundle(0, [
				"/elasticat/load/installed",
				bufL.bufnum,
				bufR.bufnum,
				bufL.numFrames,
				bufL.sampleRate,
				derivedSourceBpm,
				generation
			]);
		});

		scriptAddress.sendBundle(0, [
			"/elasticat/pool/load/installed",
			slot,
			newL.bufnum,
			newR.bufnum,
			newL.numFrames,
			newL.sampleRate,
			generation
		]);

		if(oldL.notNil, { oldL.free; });
		if(oldR.notNil and: { oldR != oldL }, { oldR.free; });
	}

	setSampleSlot { arg slot;
		var idx;
		slot = slot.asInteger;

		// Slot 0 (Off): a deliberate silence slot -- point the reader at the
		// default (zeroed) buffers so it outputs silence while the transport
		// keeps running. Useful for sequencing gaps.
		if(slot < 1, {
			sampleSlot = 0;
			this.releaseAllSlices;
			loaded = 0;
			bufL = defaultBufL;
			bufR = defaultBufR;
			this.setActive(\bufL, bufL.bufnum);
			this.setActive(\bufR, bufR.bufnum);
			scriptAddress.sendBundle(0, ["/elasticat/pool/slot/active", 0, 0, 0, ""]);
			^nil;
		});

		slot = slot.clip(1, poolSize);
		idx = slot - 1;
		sampleSlot = slot;

		if(poolLoaded[idx] != 1, {
			// Empty slot -> silence too (was: keep the previous buffer, so the
			// last-loaded sample kept playing).
			this.releaseAllSlices;
			loaded = 0;
			bufL = defaultBufL;
			bufR = defaultBufR;
			this.setActive(\bufL, bufL.bufnum);
			this.setActive(\bufR, bufR.bufnum);
			scriptAddress.sendBundle(0, ["/elasticat/pool/slot/missing", sampleSlot]);
			^nil;
		});

		this.releaseAllSlices;
		bufL = poolBufL[idx];
		bufR = poolBufR[idx];
		loaded = 1;
		sourceFrames = poolFrames[idx].max(1);
		sourceRate = poolRates[idx].max(1);
		this.recalculateNativeTempo;
		this.setActive(\bufL, bufL.bufnum);
		this.setActive(\bufR, bufR.bufnum);
		this.applyGlobals(activeSynth);
		scriptAddress.sendBundle(0, [
			"/elasticat/pool/slot/active",
			sampleSlot,
			sourceFrames,
			sourceRate,
			poolPaths[idx]
		]);
	}

	previewSlot { arg slot, startFrac, endFrac, gain, on;
		var idx;
		if(previewSynth.notNil, {
			previewSynth.set(\gate, 0);
			previewSynth = nil;
		});
		slot = slot.asInteger;
		idx = slot.clip(1, poolSize) - 1;
		if(on > 0.5 and: { slot >= 1 } and: { poolLoaded[idx] == 1 } and: { poolBufL[idx].notNil }, {
			previewSynth = Synth.tail(context.xg, \elasticatPreview, [
				\out, context.out_b.index,
				\bufL, poolBufL[idx].bufnum,
				\bufR, (poolBufR[idx] ? poolBufL[idx]).bufnum,
				\startFrac, startFrac.clip(0, 0.999),
				\endFrac, endFrac.clip(0.001, 1),
				\gain, gain.max(0)
			]);
		});
	}

	recalculateNativeTempo {
		var duration;
		duration = sourceFrames.max(1) / sourceRate.max(1);
		derivedSourceBpm = ((sampleSteps.max(1) / 4) * 60 / duration).max(1);
		sourceBpm = derivedSourceBpm;
		if(activeSynth.notNil, {
			activeSynth.set(\derivedSourceBpm, derivedSourceBpm);
		});
	}

	sendStatus {
		scriptAddress.sendBundle(0, [
			"/elasticat/requestedStatus",
			loaded,
			playing,
			modeNames.wrapAt(activeMode),
			lastPhase,
			sourceFrames,
			sourceRate,
			targetBpm,
			derivedSourceBpm,
			correction,
			lastPhaseError,
			lastErrorMs,
			modeSwitchCount,
			failedModeSwitchCount,
			hardRealignCount,
			staleClockCount,
			loadGeneration
		]);
	}

	free {
		this.releaseAllSlices;
		if(statusResponder.notNil, { statusResponder.free; });
		if(transportResponder.notNil, { transportResponder.free; });
		if(previewSynth.notNil, { previewSynth.free; });
		if(activeSynth.notNil, { activeSynth.free; });
		if(transportSynth.notNil, { transportSynth.free; });
		if(poolBufL.notNil, {
			poolBufL.do({ arg buffer, i;
				if(buffer.notNil, { buffer.free; });
				if(poolBufR[i].notNil and: { poolBufR[i] != buffer }, { poolBufR[i].free; });
			});
		});
		if(defaultBufL.notNil, { defaultBufL.free; });
		if(defaultBufR.notNil and: { defaultBufR != defaultBufL }, { defaultBufR.free; });
		if(phaseBus.notNil, { phaseBus.free; });
	}
}
