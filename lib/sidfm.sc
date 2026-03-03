// sidFM v1.0 @sonoCircuit - based on oilcan @zbs and @sixolet (thx zadie and naomi!)

Sidfm {

	*initClass {

		var voxs, params, drmGroup;

		StartUp.add {

			voxs = Array.newClear(8);
			params = [
				\pitch,
				\tune,
				\decay,
				\sweep_time,
				\sweep_depth,
				\mod_ratio,
				\mod_time,
				\mod_amp,
				\mod_fb,
				\mod_dest,
				\noise_amp,
				\noise_decay, 
				\cutoff_lpf,
				\cutoff_hpf,
				\phase,
				\fold,
				\level,
				\pan,
				\send_a,
				\send_b
			];

			OSCFunc.new({ |msg|

				if (drmGroup.isNil) {

					drmGroup = Group(Server.default);

					SynthDef(\sidFM,{

						arg out, sendABus, sendBBus,
						level = 1, pan = 0, send_a = 0, send_b = 0, gate = 1,
						pitch = 43, tune = 0, decay = 1, sweep_time = 0.1, sweep_depth = 0,
						mod_ratio = 1, mod_time = 0.1, mod_amp = 0, mod_fb = 0, mod_dest = 0,
						noise_amp = 1, noise_decay = 0.3, cutoff_lpf = 18000, cutoff_hpf = 20,
						phase = 0, fold = 0;

						var freq, dA, car_env, mod_env, noise_env, sweep_env, hz, mod, car, noise, sig;

						// rescaling
						freq = pitch.midicps * tune.midiratio;
						fold = fold.linlin(0, 1, 0, 16);
						phase = phase.linlin(1, 2, 0, pi/2);
						mod_fb = mod_fb.linlin(0, 1, 0, 10);
						
						// envelopes
						dA = Select.kr(decay >= noise_decay, [0, 2]);
						car_env = EnvGen.ar(Env.perc(0, decay, curve: -6.0), gate, doneAction: dA);
						mod_env = EnvGen.ar(Env.perc(0, decay * mod_time, curve: -8)) * mod_amp;
						noise_env = EnvGen.ar(Env.perc(0, noise_decay, noise_amp, -6.0), gate, doneAction: (2-dA));
						sweep_env = EnvGen.ar(Env.perc(0, decay * sweep_time, curve: -4.5)) * sweep_depth;

						// base frequency
						hz = Clip.ar(freq + (sweep_env * 800), 0, 10000);

						// modulator
						mod = SinOscFB.ar(hz * mod_ratio, mod_fb);
						mod = Fold.ar(mod * (fold + 1), -1, 1) * mod_env;

						// carrier
						car = SinOsc.ar(hz + (mod * 10000 * mod_dest), phase);
						car = Fold.ar(car * (fold + 1), -1, 1) * car_env;

						// noise gen
						noise = WhiteNoise.ar * noise_env;

						// mixdown
						sig = car + (mod * (1 - mod_dest)) + noise;

						// filters
						sig = LPF.ar(sig, cutoff_lpf);
						sig = HPF.ar(sig, cutoff_hpf);

						// output stage
						sig = (sig * level).tanh;
						Out.ar(out, Pan2.ar(sig, pan));
						Out.ar(sendABus, send_a * sig);
						Out.ar(sendBBus, send_b * sig);
					}).add;

					"sidFM initialized".postln;

				}

			}, "/sidfm/init");

			OSCFunc.new({ |msg|
				var drm;
				var idx = msg[1];
				var args = [params, msg[2..]].lace;

				if (drmGroup.notNil) {

					if (voxs[idx].notNil) { voxs[idx].release(0.05) };

					drm = Synth.new(\sidFM,
						[
							\sendABus, ~sendA ? Server.default.outputBus,
							\sendBBus, ~sendB ? Server.default.outputBus
						] ++ args, target: drmGroup
					);

					drm.onFree {
						if (voxs[idx].notNil && voxs[idx] === drm) { voxs[idx] = nil }
					};

					voxs[idx] = drm;

				};

			}, "/sidfm/trig");

			OSCFunc.new({ |msg|
				var drm;
				var idx = msg[1];
				var args = msg[2..];

				if (drmGroup.notNil) {

					if (voxs[idx].notNil) { voxs[idx].release(0.05) };

					drm = Synth.new(\sidFM,
						[
							\sendABus, ~sendA ? Server.default.outputBus,
							\sendBBus, ~sendB ? Server.default.outputBus
						] ++ args, target: drmGroup
					);

					drm.onFree {
						if (voxs[idx].notNil && voxs[idx] === drm) { voxs[idx] = nil }
					};

					voxs[idx] = drm;

				};

			}, "/sidfm/preview");

		};
	}
}