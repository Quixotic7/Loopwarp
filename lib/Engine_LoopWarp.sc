// LoopWarp v2 foundation.
//
// One shared server-side transport phase drives one active mode synth at a time.
// Existing mode families are preserved under technically accurate names:
//   0 tape              former basic
//   1 tempo_varispeed   former classic
//   2 chopped
//   3 granular
//   4 random_ola        former wsola-style random overlap grains
//   5 pitch_corrected   former pv/PitchShift color
Engine_LoopWarp : CroneEngine {

	var <transportSynth;
	var <activeSynth;
	var <bufL;
	var <bufR;
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

	*new { arg context, doneCallback;
		^super.new(context, doneCallback);
	}

	alloc {
		var server;
		server = context.server;
		scriptAddress = NetAddr("localhost", 10111);
		modeSynthNames = [
			\loopWarpTape,
			\loopWarpTempoVarispeed,
			\loopWarpChopped,
			\loopWarpGranular,
			\loopWarpRandomOla,
			\loopWarpPitchCorrected
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

		this.addSynthDefs;
		server.sync;

		transportResponder = OSCFunc({
			arg msg;
			lastPhase = msg[3].asFloat;
			correction = msg[4].asFloat;
			if(debugLevel >= 3, {
				scriptAddress.sendBundle(0, [
					"/loopwarp/transport",
					lastPhase,
					correction,
					msg[5].asFloat
				]);
			});
		}, path: '/loopwarp/transportRaw', srcID: server.addr);

		statusResponder = OSCFunc({
			arg msg;
			lastPhase = msg[4].asFloat;
			scriptAddress.sendBundle(0, [
				"/loopwarp/status",
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
		}, path: '/loopwarp/statusRaw', srcID: server.addr);

		transportSynth = Synth.new(\loopWarpTransport, [
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
		SynthDef(\loopWarpTransport, {
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
			SendReply.kr(Impulse.kr(1), cmdName: '/loopwarp/transportRaw', values: [
				phase,
				correction,
				targetBpm
			]);
		}).add;

		this.addDirectReaderDef(\loopWarpTape, 0);
		this.addDirectReaderDef(\loopWarpTempoVarispeed, 1);

		SynthDef(\loopWarpChopped, {
			arg out=0, phaseBus=0, bufL=0, bufR=0, modeAmp=1, fadeTime=0.05,
			playing=0, resetTrig=0, resetPos=0,
			amp=0.8, pan=0, pitch=0, targetBpm=120, loopBeats=4, macro=0,
			startPoint=0, endPoint=128, chopBeats=0.25, chopMode=0, chopAttack=0.002, chopHold=0.04, chopRelease=0.01;
			var phase, frames, pos, trig, beatDur, duty, env, sig, modeGain, playGate, startNorm, range, readPhase;
			var pitchSmooth, sliceWidth, sliceStart, localPhase, forwardStop, loopForward, pingPong, pingPongPhase, stepRate, stopGate;
			phase = In.ar(phaseBus, 1);
			frames = BufFrames.kr(bufL).max(4);
			startNorm = Lag.kr(startPoint.clip(0, 127.99) / 128, 0.02);
			range = Lag.kr(((endPoint.clip(startPoint + 0.01, 128) - startPoint.clip(0, 127.99)) / 128).clip(0.0001, 1), 0.02);
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
			SendReply.kr(Impulse.kr(1), cmdName: '/loopwarp/statusRaw', values: [
				2, phase, frames, Amplitude.kr(sig[0]), Amplitude.kr(sig[1])
			]);
			Out.ar(out, sig);
		}).add;

		SynthDef(\loopWarpGranular, {
			arg out=0, phaseBus=0, bufL=0, bufR=0, modeAmp=1, fadeTime=0.05,
			playing=0, resetTrig=0, resetPos=0,
			amp=0.8, pan=0, pitch=0, targetBpm=120, loopBeats=4, macro=0,
			startPoint=0, endPoint=128, grainSize=0.08, grainOverlap=8, grainJitter=0.0, grainSpray=0.0;
			var phase, frames, pos, dur, randomness, direct, wet, sig, modeGain, playGate, gainNorm, startNorm, range, readPhase, stepDur, overlap, overlapControl;
			phase = In.ar(phaseBus, 1);
			frames = BufFrames.kr(bufL).max(4);
			startNorm = Lag.kr(startPoint.clip(0, 127.99) / 128, 0.02);
			range = Lag.kr(((endPoint.clip(startPoint + 0.01, 128) - startPoint.clip(0, 127.99)) / 128).clip(0.0001, 1), 0.02);
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
			SendReply.kr(Impulse.kr(1), cmdName: '/loopwarp/statusRaw', values: [
				3, phase, frames, Amplitude.kr(sig[0]), Amplitude.kr(sig[1])
			]);
			Out.ar(out, sig);
		}).add;

		SynthDef(\loopWarpRandomOla, {
			arg out=0, phaseBus=0, bufL=0, bufR=0, modeAmp=1, fadeTime=0.05,
			playing=0, resetTrig=0, resetPos=0,
			amp=0.8, pan=0, pitch=0, targetBpm=120, loopBeats=4, macro=0,
			startPoint=0, endPoint=128, grainSize=0.1, grainOverlap=6, wander=0.03, timingJitter=0.0;
			var phase, frames, trig, dur, rate, chaos, pos, offset, direct, wet, sig, modeGain, playGate, gainNorm, startNorm, range, readPhase, stepDur, overlapControl, wanderControl;
			phase = In.ar(phaseBus, 1);
			frames = BufFrames.kr(bufL).max(4);
			startNorm = Lag.kr(startPoint.clip(0, 127.99) / 128, 0.02);
			range = Lag.kr(((endPoint.clip(startPoint + 0.01, 128) - startPoint.clip(0, 127.99)) / 128).clip(0.0001, 1), 0.02);
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
			SendReply.kr(Impulse.kr(1), cmdName: '/loopwarp/statusRaw', values: [
				4, phase, frames, Amplitude.kr(sig[0]), Amplitude.kr(sig[1])
			]);
			Out.ar(out, sig);
		}).add;

		SynthDef(\loopWarpPitchCorrected, {
			arg out=0, phaseBus=0, bufL=0, bufR=0, modeAmp=1, fadeTime=0.05,
			playing=0, resetTrig=0, resetPos=0,
			amp=0.8, pan=0, pitch=0, targetBpm=120, derivedSourceBpm=120, loopBeats=4,
			startPoint=0, endPoint=128, pvWindow=0.2, pvDispersion=0, pvTimeDispersion=0, macro=0;
			var phase, frames, pos, raw, shifted, ratio, sig, modeGain, playGate, window, startNorm, range, readPhase;
			phase = In.ar(phaseBus, 1);
			frames = BufFrames.kr(bufL).max(4);
			startNorm = Lag.kr(startPoint.clip(0, 127.99) / 128, 0.02);
			range = Lag.kr(((endPoint.clip(startPoint + 0.01, 128) - startPoint.clip(0, 127.99)) / 128).clip(0.0001, 1), 0.02);
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
			SendReply.kr(Impulse.kr(1), cmdName: '/loopwarp/statusRaw', values: [
				5, phase, frames, Amplitude.kr(sig[0]), Amplitude.kr(sig[1])
			]);
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
			startNorm = Lag.kr(startPoint.clip(0, 127.99) / 128, 0.02);
			range = Lag.kr(((endPoint.clip(startPoint + 0.01, 128) - startPoint.clip(0, 127.99)) / 128).clip(0.0001, 1), 0.02);
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
			SendReply.kr(Impulse.kr(1), cmdName: '/loopwarp/statusRaw', values: [
				modeId, phase, frames, Amplitude.kr(sig[0]), Amplitude.kr(sig[1])
			]);
			Out.ar(out, sig);
		}).add;
	}

	installCommands {
		this.addCommand(\loadSample, "s", { arg msg; this.loadSample(msg[1]); });
		this.addCommand(\play, "i", { arg msg; this.play(msg[1]); });
		this.addCommand(\pause, "", { this.play(0); });
		this.addCommand(\stopAndReset, "", { this.stopAndReset; });
		this.addCommand(\stop, "", { this.stopAndReset; });
		this.addCommand(\reset, "", { this.setPlayhead(0); });
		this.addCommand(\setMode, "i", { arg msg; this.setMode(msg[1]); });
		this.addCommand(\mode, "i", { arg msg; this.setMode(msg[1]); });
		this.addCommand(\setModeProfile, "i", { arg msg;
			scriptAddress.sendBundle(0, ["/loopwarp/profile", msg[1].asInteger]);
		});
		this.addCommand(\setModeMacro, "f", { arg msg; modeMacro = msg[1].clip(0, 1); this.setActive(\macro, modeMacro); });
		this.addCommand(\setModeParam, "sf", { arg msg; this.setActive(msg[1].asSymbol, msg[2]); });
		this.addCommand(\setModeSwitchFade, "f", { arg msg; modeSwitchFade = msg[1].clip(0.001, 0.25); });
		this.addCommand(\setModeSwitchQuantization, "i", { arg msg;
			scriptAddress.sendBundle(0, ["/loopwarp/switchQuantization", msg[1].asInteger]);
		});
		this.addCommand(\setSampleSteps, "f", { arg msg; this.setSampleSteps(msg[1]); });
		this.addCommand(\sampleSteps, "f", { arg msg; this.setSampleSteps(msg[1]); });
		this.addCommand(\setLoopBeats, "f", { arg msg; this.setSampleSteps(msg[1] * 4); });
		this.addCommand(\loopBeats, "f", { arg msg; this.setSampleSteps(msg[1] * 4); });
		this.addCommand(\setLoopPreview, "ff", { arg msg;
			scriptAddress.sendBundle(0, ["/loopwarp/loopPreview", msg[1].clip(0, 1), msg[2].clip(0, 1)]);
		});
		this.addCommand(\commitLoop, "ff", { arg msg;
			scriptAddress.sendBundle(0, ["/loopwarp/commitLoopPending", msg[1].clip(0, 1), msg[2].clip(0, 1)]);
		});
		this.addCommand(\setPitch, "f", { arg msg; pitch = msg[1].clip(-24, 24); this.setActive(\pitch, pitch); });
		this.addCommand(\pitch, "f", { arg msg; pitch = msg[1].clip(-24, 24); this.setActive(\pitch, pitch); });
		this.addCommand(\setSpeed, "f", { arg msg; speed = msg[1].clip(0.03125, 8); this.setActive(\speed, speed); });
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
		this.addCommand(\xfade, "f", { arg msg; loopXfade = msg[1].clip(0, 0.25); });
		this.addCommand(\chopSteps, "f", { arg msg; this.setActive(\chopBeats, msg[1].max(0.03125) / 4); });
		this.addCommand(\chopBeats, "f", { arg msg; this.setActive(\chopBeats, msg[1]); });
		this.addCommand(\chopLoopMode, "i", { arg msg; this.setActive(\chopMode, msg[1].asInteger.clip(0, 2)); });
		this.addCommand(\chopAttack, "f", { arg msg; this.setActive(\chopAttack, msg[1]); });
		this.addCommand(\chopHold, "f", { arg msg; this.setActive(\chopHold, msg[1]); });
		this.addCommand(\chopRelease, "f", { arg msg; this.setActive(\chopRelease, msg[1]); });
		this.addCommand(\grainSize, "f", { arg msg; this.setActive(\grainSize, msg[1]); });
		this.addCommand(\grainDensity, "f", { arg msg; this.setActive(\grainOverlap, msg[1]); });
		this.addCommand(\grainJitter, "f", { arg msg; this.setActive(\grainJitter, msg[1]); this.setActive(\grainSpray, msg[1]); });
		this.addCommand(\wsolaWindow, "f", { arg msg; this.setActive(\grainSize, msg[1]); });
		this.addCommand(\wsolaSearch, "f", { arg msg; this.setActive(\wander, msg[1]); });
		this.addCommand(\pvWindow, "f", { arg msg; this.setActive(\pvWindow, msg[1]); });
		this.addCommand(\pvDispersion, "f", { arg msg; this.setActive(\pvDispersion, msg[1]); });
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
				\pitch, pitch,
				\speed, speed,
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
		this.updateTransport;
		this.setActive(\playing, playing);
		scriptAddress.sendBundle(0, ["/loopwarp/play", playing]);
	}

	stopAndReset {
		this.play(0);
		this.setPlayhead(0);
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
		scriptAddress.sendBundle(0, ["/loopwarp/reset", lastPhase]);
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
		scriptAddress.sendBundle(0, ["/loopwarp/mode", modeNames.wrapAt(activeMode), activeMode, modeSwitchCount]);
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
		var sf, channels, generation;
		if(path.isNil, { ^nil; });
		path = path.asString;
		loadGeneration = loadGeneration + 1;
		generation = loadGeneration;
		scriptAddress.sendBundle(0, ["/loopwarp/load/request", path, generation]);

		sf = SoundFile.openRead(path);
		if(sf.isNil, {
			scriptAddress.sendBundle(0, ["/loopwarp/load/failed", path, generation]);
			^nil;
		});
		channels = sf.numChannels;
		sourceFrames = sf.numFrames;
		sourceRate = sf.sampleRate;
		sf.close;
		this.recalculateNativeTempo;
		scriptAddress.sendBundle(0, ["/loopwarp/load/opened", path, channels, sourceFrames, sourceRate, generation]);

		Buffer.readChannel(server: context.server, path: path, startFrame: 0, numFrames: -1, channels: [0], action: {
			arg newL;
			if(generation != loadGeneration, {
				newL.free;
				staleClockCount = staleClockCount + 1;
			}, {
				if(newL.numFrames <= 0, {
					newL.free;
					scriptAddress.sendBundle(0, ["/loopwarp/load/failed", path, generation]);
				}, {
					scriptAddress.sendBundle(0, ["/loopwarp/load/readDone", 0, newL.numFrames, newL.numChannels, generation]);
					if(channels > 1, {
						Buffer.readChannel(server: context.server, path: path, startFrame: 0, numFrames: -1, channels: [1], action: {
							arg newR;
							if(generation != loadGeneration, {
								newL.free;
								newR.free;
							}, {
								scriptAddress.sendBundle(0, ["/loopwarp/load/readDone", 1, newR.numFrames, newR.numChannels, generation]);
								this.installBuffers(newL, newR, generation);
							});
						});
					}, {
						this.installBuffers(newL, newL, generation);
					});
				});
			});
		});
	}

	installBuffers { arg newL, newR, generation;
		var oldL, oldR, oldSynth, newSynth;
		if(generation != loadGeneration, {
			newL.free;
			if(newR != newL, { newR.free; });
			^nil;
		});

		oldL = bufL;
		oldR = bufR;
		oldSynth = activeSynth;
		bufL = newL;
		bufR = newR;
		loaded = 1;
		sourceFrames = bufL.numFrames;
		sourceRate = bufL.sampleRate;
		this.recalculateNativeTempo;

		newSynth = this.spawnMode(activeMode, 0);
		this.applyGlobals(newSynth);
		activeSynth = newSynth;
		activeSynth.set(\modeAmp, 1, \fadeTime, modeSwitchFade);

		if(oldSynth.notNil, {
			oldSynth.set(\modeAmp, 0, \fadeTime, modeSwitchFade);
		});

		Routine({
			modeSwitchFade.wait;
			if(oldSynth.notNil, { oldSynth.free; });
			if(oldL.notNil, { oldL.free; });
			if(oldR.notNil and: { oldR != oldL }, { oldR.free; });
		}).play(SystemClock);

		scriptAddress.sendBundle(0, [
			"/loopwarp/load/installed",
			bufL.bufnum,
			bufR.bufnum,
			bufL.numFrames,
			bufL.sampleRate,
			derivedSourceBpm,
			generation
		]);
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
			"/loopwarp/requestedStatus",
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
		if(statusResponder.notNil, { statusResponder.free; });
		if(transportResponder.notNil, { transportResponder.free; });
		if(activeSynth.notNil, { activeSynth.free; });
		if(transportSynth.notNil, { transportSynth.free; });
		if(bufL.notNil, { bufL.free; });
		if(bufR.notNil and: { bufR != bufL }, { bufR.free; });
		if(phaseBus.notNil, { phaseBus.free; });
	}
}
