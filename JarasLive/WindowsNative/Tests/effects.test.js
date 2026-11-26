import test from 'node:test';
import assert from 'node:assert/strict';
import {effectDefaults,effectEntry,insertNativeEffect,equalizerResponse} from '../ui/app-effects.js';
test('native FX instances retain independent portable settings and original opaque plugins',()=>{
  const settings={inserted:['External:existing'],externalPlugins:[{id:'existing',name:'Plugin',componentState:'unchanged'}]};
  const a=insertNativeEffect(settings,'EQ'),b=insertNativeEffect(settings,'EQ');
  assert.notEqual(a,b);effectEntry(settings,a).value.bands[2].gain=6;
  assert.equal(effectEntry(settings,b).value.bands[2].gain,0);
  assert.equal(settings.externalPlugins[0].componentState,'unchanged');
  const restored=JSON.parse(JSON.stringify(settings));assert.equal(effectEntry(restored,a).value.bands[2].gain,6);
  assert.equal(effectEntry(restored,'External:existing').name,'Plugin');
  assert.throws(()=>insertNativeEffect(settings,'Unknown'));
});
test('equalizer response matches unity, exact center gain and sample-rate-aware cut slopes',()=>{
  for(const rate of [44100,48000,96000]) {
    assert.equal(equalizerResponse([],1000,rate),0);
    for(const gain of [-24,-6,0,6,24]) {
      const band={frequency:1000,gain,q:.707,type:'bell',enabled:true};
      assert.ok(Math.abs(equalizerResponse([band],1000,rate)-gain)<1e-8);
      assert.equal(equalizerResponse([{...band,enabled:false}],1000,rate),0);
    }
    for(const slope of [6,12,24,48,96]) {
      const cut={frequency:1000,type:'lowCut',slope,enabled:true};
      assert.ok(Math.abs(equalizerResponse([cut],1000,rate)+3.0102999566)<1e-7);
      assert.ok(equalizerResponse([cut],100,rate)<-slope*2.9);
    }
    const shelf={frequency:1000,q:.707,gain:12,type:'lowShelf'};
    assert.ok(equalizerResponse([shelf],20,rate)>11.9);
    assert.ok(Math.abs(equalizerResponse([shelf],rate*.4,rate))<.01);
  }
});
test('native controls use identical stored units and defaults as NativeFX',()=>{
  assert.equal(effectDefaults('Compressor').attack,.005);
  assert.equal(effectDefaults('Delay').delayTime,.25);
  assert.equal(effectDefaults('Cat Gate').gate.filterOutput,false);
  assert.equal(effectDefaults('CatLive Trigger').trigger.release,.02);
  assert.equal(effectDefaults('EQ').bands.length,5);
  assert.ok(effectDefaults('EQ').bands.every(b=>b.id&&b.enabled));
});
