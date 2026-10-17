// Compare compiled native state with the reference algorithm using a fixed seed.
const fs=require('fs'), vm=require('vm'), cp=require('child_process'), assert=require('assert/strict');
const reference=process.argv[2]||'../hamster-html';
const binary=process.argv[3]||'/private/tmp/hamster-native-verify';
const native=cp.execFileSync(binary,['--trace'],{encoding:'utf8'}).trim().split('\n').map(JSON.parse);
class Path2D {
 constructor(){this.commands=[];}
 moveTo(x,y){this.commands.push([0,x,y]);}
 lineTo(x,y){this.commands.push([1,x,y]);}
 quadraticCurveTo(cx,cy,x,y){this.commands.push([2,cx,cy,x,y]);}
}
const ctx=vm.createContext({Path2D,performance:{now:()=>0},setTimeout(){return 0},clearTimeout(){},console});
ctx.window=ctx;
vm.runInContext(fs.readFileSync(reference+'/src/runtime.js','utf8')+'\n'+fs.readFileSync(reference+'/src/original.js','utf8')+`
let seed=11042;Math.random=()=>{seed=(seed*1664525+1013904223)>>>0;return seed/4294967296;};
setManualClock(true);
const globals=new Set(['Math','Object','Array','parseInt','undefined','System','WaterBottle','Hamster','Food','TextFormat','com','identity']);
const root=new Proxy(new MovieClip(),{has:(_,key)=>typeof key==='string'&&!globals.has(key),get:(target,key,receiver)=>Reflect.get(target,key,receiver)});initializeTimeline.call(root,root);
function run(){root.onEnterFrame.call(root);root.ham.onEnterFrame.call(root.ham);}
run();
`,ctx);
let comparisons=0;
for(let i=0,frame=0;i<native.length;i++){
 const expected=native[i];
 while(frame<expected.frame){vm.runInContext('advanceTimers();run()',ctx);frame++;}
 const actual=vm.runInContext('({root,ham:root.ham})',ctx);
 for(const kind of ['root','ham'])for(const [key,value] of Object.entries(expected[kind])){
  if(key==='_removed')continue;
  const target=actual[kind][key];
  const normalized=target===undefined||Number.isNaN(target)?null:target;
  if(typeof value==='number'&&typeof normalized==='number'){
   if(Math.abs(value-normalized)>1e-8*Math.max(1,Math.abs(normalized)))throw Error('frame '+frame+' '+kind+'.'+key+': native='+value+' reference='+normalized);
  }else assert.equal(value,normalized,'frame '+frame+' '+kind+'.'+key);
  comparisons++;
 }
}
console.log('PASS: '+comparisons+' native/reference state values across 16,000 frames with identical seeded randomness');

const geometries=cp.execFileSync(binary,['--geometry'],{encoding:'utf8',maxBuffer:32*1024*1024}).trim().split('\n').map(JSON.parse);
vm.runInContext('seed=11042;flashTimers.clear();flashTime=0;timerId=0;',ctx);
// A fresh context is needed because the original timeline retains its object graph.
const fresh=vm.createContext({Path2D,performance:{now:()=>0},setTimeout(){return 0},clearTimeout(){},console});fresh.window=fresh;
vm.runInContext(fs.readFileSync(reference+'/src/runtime.js','utf8')+'\n'+fs.readFileSync(reference+'/src/original.js','utf8')+`
let seed=11042;Math.random=()=>{seed=(seed*1664525+1013904223)>>>0;return seed/4294967296;};setManualClock(true);
const globals=new Set(['Math','Object','Array','parseInt','undefined','System','WaterBottle','Hamster','Food','TextFormat','com','identity']);
const root=new Proxy(new MovieClip(),{has:(_,key)=>typeof key==='string'&&!globals.has(key),get:(target,key,receiver)=>Reflect.get(target,key,receiver)});initializeTimeline.call(root,root);
function run(){root.onEnterFrame.call(root);root.ham.onEnterFrame.call(root.ham);}run();
function geometry(v){
 function shapes(list){return list.map(s=>{const rgba=s.color.match(/[\\d.]+/g).map(Number);return {color:(rgba[0]<<16)|(rgba[1]<<8)|rgba[2],alpha:rgba[3],width:s.width||0,path:s.path.commands};});}
 return {name:v._name===undefined?'undefined':v._name,fills:shapes(v.fills),strokes:shapes(v.strokes),children:v.children.map(geometry)};
}`,fresh);
let geometryValues=0;
function compare(a,b,path){
 if(typeof a==='number'&&typeof b==='number'){assert.ok(Math.abs(a-b)<=1e-8*Math.max(1,Math.abs(b)),path+': '+a+' vs '+b);geometryValues++;return;}
 if(Array.isArray(a)){assert.equal(a.length,b.length,path+'.length');a.forEach((v,i)=>compare(v,b[i],path+'['+i+']'));return;}
 if(a&&typeof a==='object'){for(const k of Object.keys(a))compare(a[k],b[k],path+'.'+k);return;}
 assert.equal(a,b,path);
}
for(let i=0,frame=0;i<4;i++){
 const target=[0,100,500,5000][i];while(frame<target){vm.runInContext('advanceTimers();run()',fresh);frame++;}
 const actual=vm.runInContext('geometry(root)',fresh);compare(geometries[i],actual,'frame '+frame);
}
console.log('PASS: '+geometryValues+' native/reference path coordinates and styles at 4 animation checkpoints');
