const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname, '../src/timecode-lan.js'), 'utf8');
const start=source.indexOf('  function nextTickIntervalMs('), end=source.indexOf('\n  function scheduleNextTick(',start);
const scope=vm.createContext({localStatus:null,licenseIsActive:()=>true,isPairCode:c=>/^\d{6}$/.test(c),
 statusCanTransmit:s=>s.mode==='transmitter'||s.mode==='project_sync',statusCanReceive:s=>s.mode==='receive',
 projectSyncBundlePullPromise:null,projectSyncRoleHandoverPromise:null,projectSyncApplyIsActive:()=>false,safePreflightRequestId:()=>'',
 transmitterPeer:null,receiverSession:null,
 TRANSMIT_INTERVAL_MS:20,CONNECTED_IDLE_INTERVAL_MS:40,RECEIVER_IDLE_INTERVAL_MS:80,PAIRING_IDLE_INTERVAL_MS:100,DISABLED_IDLE_INTERVAL_MS:500});
vm.runInContext(source.slice(start,end),scope);
assert.equal(scope.nextTickIntervalMs(),500);
for(const playState of [0,1,2,5]) {
 scope.localStatus={code:'',mode:'disabled',transport:{playState}};
 assert.equal(scope.nextTickIntervalMs(),500,'unconfigured relay stays light even while REAPER plays');
 scope.localStatus={code:'123456',mode:'disabled',transport:{playState}};
 assert.equal(scope.nextTickIntervalMs(),500,'a leftover pairing code does not activate disabled mode');
}
scope.localStatus={code:'123456',mode:'transmitter',transport:{playState:1}};
assert.equal(scope.nextTickIntervalMs(),20,'active playback preserves low latency without any window dependency');
scope.localStatus.transport.playState=0;
assert.equal(scope.nextTickIntervalMs(),100,'pairing remains responsive');
scope.transmitterPeer={connected:true};assert.equal(scope.nextTickIntervalMs(),40);
scope.transmitterPeer=null;scope.receiverSession={};scope.localStatus.mode='receive';assert.equal(scope.nextTickIntervalMs(),80);
scope.localStatus.mode='project_sync';scope.projectSyncBundlePullPromise={};assert.equal(scope.nextTickIntervalMs(),20,'file transfer remains responsive');
scope.licenseIsActive=()=>false;assert.equal(scope.nextTickIntervalMs(),500);
console.log('RELAY_IDLE_PERFORMANCE_OK: disabled playback, pairing, active sync, transfer and license transitions');
