// Mechanical source-to-source port: JavaScript syntax -> compiled C++ operations.
// No JavaScript engine or webpage is included in the application.
const fs = require('fs');
const crypto = require('crypto');
let ts; try { ts = require('typescript'); } catch { ts = require('/usr/local/lib/node_modules/typescript'); }
const input = process.argv[2] || '../hamster-html/src/original.js';
const source = fs.readFileSync(input, 'utf8');
const tree = ts.createSourceFile('original.js', source, ts.ScriptTarget.Latest, true, ts.ScriptKind.JS);
const K = ts.SyntaxKind;
const properties = new Set(`_x _y _rotation _xscale _yscale _alpha _visible _parent _name _depth _width _height length createEmptyMovieClip attachMovie createTextField getNextHighestDepth getDepth swapDepths removeMovieClip setMask clear lineStyle beginFill endFill moveTo lineTo curveTo setTextFormat push pop splice sort prototype symbolName onEnterFrame onMouseMove onMouseDown onMouseUp x y z format text size font color url target isMask _removed`.split(' '));
function scan(n) {
 if(ts.isPropertyAccessExpression(n)) properties.add(n.name.text);
 if(ts.isPropertyAssignment(n)||ts.isPropertyDeclaration(n)||ts.isMethodDeclaration(n)) properties.add(n.name.text);
 ts.forEachChild(n,scan);
}
scan(tree);
for(const c of tree.statements.filter(ts.isClassDeclaration)) properties.add(c.name.text);
for(const n of ['MovieClip','Object','Array','TextFormat','Stage','com','_global','Math','System','security','allowDomain','setTimeout','clearTimeout','width','height','abowman','graphics','math','up_wheelCenterColor','up_wheelSpokeColor']) properties.add(n);
const pid = n => 'P_' + n;
let functions=[], setups=[], globals=new Set(tree.statements.filter(ts.isClassDeclaration).map(c=>c.name.text));
const runtimeGlobals=new Set(['com','Stage','_global','System','MovieClip','TextFormat']);
let count=0;
const q=JSON.stringify;
function locals(body, params) {
 const names=new Set(params.map(p=>p.name.text));
 function visit(n) { if(ts.isFunctionExpression(n)) return; if(ts.isVariableDeclaration(n)) names.add(n.name.text); ts.forEachChild(n,visit); }
 visit(body); return names;
}
function fn(n, name, withRoot=false) {
 const names=locals(n.body,n.parameters || []);
 const ctx={names,withRoot};
 const params=(n.parameters||[]).map(p=>p.name.text);
 const head=params.map((p,i)=>`[[maybe_unused]] V v_${p}=arg(a,${i});`).join('\n')+'\n'+[...names].filter(n=>!params.includes(n)).map(n=>`[[maybe_unused]] V v_${n};`).join('\n');
 const body=stmt(n.body,ctx);
 functions.push(`static V ${name}(V self,const Args& a) {\n${head}\n${body}\nreturn {};\n}`);
 return `function(${name})`;
}
function id(n,c) {
 if(n==='undefined')return 'V()';
 if(c.names.has(n))return 'v_'+n;
 if(globals.has(n)||runtimeGlobals.has(n))return `G(E->globals,${pid(n)})`;
 if(n==='arguments')return 'array(a)';
 if(c.withRoot)return `G(E->root,${pid(n)})`;
 throw Error('Unknown identifier '+n);
}
function ref(n,c) {
 if(ts.isIdentifier(n)) return c.names.has(n.text)?'v_'+n.text:`R(E->root,${pid(n.text)})`;
 if(ts.isPropertyAccessExpression(n))return `R(${expr(n.expression,c)},${pid(n.name.text)})`;
 if(ts.isElementAccessExpression(n))return `indexRef(${expr(n.expression,c)},${expr(n.argumentExpression,c)})`;
 throw Error('Invalid ref '+n.getText(tree));
}
function expr(n,c) {
 if(!n)return 'V()';
 if(ts.isIdentifier(n))return id(n.text,c);
 if(n.kind===K.ThisKeyword)return 'self';
 if(n.kind===K.NullKeyword)return 'V()';
 if(ts.isNumericLiteral(n))return `V(${n.text})`;
 if(ts.isStringLiteral(n))return `string(${q(n.text)})`;
 if(n.kind===K.TrueKeyword)return 'V(true)';
 if(n.kind===K.FalseKeyword)return 'V(false)';
 if(ts.isParenthesizedExpression(n))return '('+expr(n.expression,c)+')';
 if(ts.isObjectLiteralExpression(n))return `object({${n.properties.map(p=>`{${pid(p.name.text)},${expr(p.initializer,c)}}`).join(',')}})`;
 if(ts.isArrayLiteralExpression(n))return `array({${n.elements.map(e=>expr(e,c)).join(',')}})`;
 if(ts.isPropertyAccessExpression(n))return `G(${expr(n.expression,c)},${pid(n.name.text)})`;
 if(ts.isElementAccessExpression(n))return `indexGet(${expr(n.expression,c)},${expr(n.argumentExpression,c)})`;
 if(ts.isBinaryExpression(n)) {
  const op=n.operatorToken.getText(tree);
  if(['=','+=','-=','*=','/=','%='].includes(op))return `(${ref(n.left,c)} ${op} ${expr(n.right,c)})`;
  if(op==='&&'||op==='||')return `V(bool(${expr(n.left,c)}) ${op} bool(${expr(n.right,c)}))`;
  return `V(${expr(n.left,c)} ${op} ${expr(n.right,c)})`;
 }
 if(ts.isPrefixUnaryExpression(n)) { const op=ts.tokenToString(n.operator); return `V(${op}${expr(n.operand,c)})`; }
 if(ts.isPostfixUnaryExpression(n)) return `(${ref(n.operand,c)}${ts.tokenToString(n.operator)})`;
 if(ts.isConditionalExpression(n))return `(bool(${expr(n.condition,c)}) ? ${expr(n.whenTrue,c)} : ${expr(n.whenFalse,c)})`;
 if(ts.isFunctionExpression(n)) return fn(n,'timeline_'+count++,true);
 if(ts.isNewExpression(n)) {
  const name=n.expression.getText(tree);
  if(name==='Array')return 'array({})';
  if(name==='Object'||name==='TextFormat')return 'object({})';
  throw Error('Unknown new '+name);
 }
 if(ts.isCallExpression(n)) {
  const name=n.expression.getText(tree), aa=n.arguments.map(v=>expr(v,c));
  if(name==='super'||name==='trace'||name.startsWith('System.')||name.startsWith('Object.prototype.'))return 'V()';
  if(name==='identity')return aa[0];
  if(name==='registerClass')return 'V(true)';
  if(name==='parseInt')return `parseNumber(${aa[0]})`;
  if(name==='isNaN')return `V(std::isnan(number(${aa[0]})))`;
  if(name==='int')return `V(std::trunc(number(${aa[0]})))`;
  if(name==='flashSetInterval')return `schedule(${aa.join(',')},true)`;
  if(name.startsWith('Math.')) {
   const method=name.slice(5);
   if(method==='random')return 'V(E->random())';
   const map={min:'fmin',max:'fmax',abs:'fabs',round:'roundJS'};
   return `V(${method==='round'?'roundJS':'std::'+(map[method]||method)}(${aa.map(a=>'number('+a+')').join(',')}))`;
  }
  if(ts.isPropertyAccessExpression(n.expression)) return `call(${expr(n.expression.expression,c)},${pid(n.expression.name.text)},{${aa.join(',')}})`;
  if(ts.isIdentifier(n.expression)&&c.withRoot&&!c.names.has(n.expression.text))return `call(E->root,${pid(n.expression.text)},{${aa.join(',')}})`;
  return `invoke(${expr(n.expression,c)},self,{${aa.join(',')}})`;
 }
 throw Error('Unsupported expression '+K[n.kind]+' '+n.getText(tree));
}
function stmt(n,c) {
 if(ts.isBlock(n))return '{\n'+n.statements.map(s=>stmt(s,c)).join('\n')+'\n}';
 if(ts.isExpressionStatement(n))return expr(n.expression,c)+';';
 if(ts.isVariableStatement(n))return n.declarationList.declarations.filter(d=>d.initializer).map(d=>`v_${d.name.text} = ${expr(d.initializer,c)};`).join('\n');
 if(ts.isIfStatement(n)) {
  if(n.expression.getText(tree).includes('Object.prototype.hasOwnProperty'))return '';
  return `if(bool(${expr(n.expression,c)})) ${stmt(n.thenStatement,c)}${n.elseStatement?' else '+stmt(n.elseStatement,c):''}`;
 }
 if(ts.isWhileStatement(n))return `while(bool(${expr(n.expression,c)})) ${stmt(n.statement,c)}`;
 if(ts.isReturnStatement(n))return 'return '+expr(n.expression,c)+';';
 if(ts.isBreakStatement(n))return 'break;';
 if(ts.isSwitchStatement(n))return `switch(int(number(${expr(n.expression,c)}))) {\n${n.caseBlock.clauses.map(cl=>(cl.expression?'case '+cl.expression.getText(tree):'default')+':\n'+cl.statements.map(s=>stmt(s,c)).join('\n')).join('\n')}\n}`;
 if(ts.isWithStatement(n))return stmt(n.statement,{...c,withRoot:true});
 if(n.kind===K.EmptyStatement)return '';
 throw Error('Unsupported statement '+K[n.kind]);
}
for(const cls of tree.statements.filter(ts.isClassDeclaration)) {
 const name=cls.name.text;
 let setup=`V cls_${name}=object({}); R(E->globals,${pid(name)})=cls_${name};\nV proto_${name}=object({}); cls_${name}.o->instancePrototype=proto_${name}.o;`;
 if(cls.heritageClauses)setup+=`\nproto_${name}.o->prototype=E->clipPrototype.o;`;
 for(const m of cls.members.filter(ts.isMethodDeclaration)) {
  const stat=m.modifiers?.some(m=>m.kind===K.StaticKeyword);
  setup+=`\nR(${stat?'cls_':'proto_'}${name},${pid(m.name.text)})=${fn(m, name+'_'+m.name.text)};`;
 }
 const fields=cls.members.filter(ts.isPropertyDeclaration);
 const ic={names:new Set(),withRoot:false};
 functions.push(`static V initialize_${name}(V self,const Args& a) {\n${fields.filter(m=>!m.modifiers?.some(m=>m.kind===K.StaticKeyword)&&m.initializer).map(m=>`R(self,${pid(m.name.text)})=${expr(m.initializer,ic)};`).join('\n')}\nreturn self;\n}`);
 setup+=`\ncls_${name}.o->initializer=initialize_${name};`;
 for(const m of fields.filter(m=>m.modifiers?.some(m=>m.kind===K.StaticKeyword)&&m.initializer))setup+=`\nR(cls_${name},${pid(m.name.text)})=${expr(m.initializer,ic)};`;
 setups.push(setup);
}
const timeline=tree.statements.find(ts.isFunctionDeclaration);
fn(timeline,'initializeTimeline',true);
// Register any implicit timeline variables discovered while emitting.
const allCode=[...functions,...setups].join('\n');
for(const m of allCode.matchAll(/\bP_(\w+)/g))properties.add(m[1]);
const sorted=[...properties].sort();
const header='// Generated property IDs; direct integer lookup avoids string lookup per frame.\n#pragma once\nenum Property {\n'+sorted.map(n=>pid(n)).join(',\n')+',\nPropertyCount\n};\nstatic const char* const propertyNames[]={'+sorted.map(q).join(',')+'};\n';
fs.writeFileSync('hamster-mac/Native/Properties.hpp',header);
fs.writeFileSync('hamster-mac/Native/Original.hpp',`// Native C++ port of original.js; generated by scripts/port-native.cjs.\n// Source SHA-256: ${crypto.createHash('sha256').update(source).digest('hex')}\n// Original aBowman implementation and attribution retained.\n${functions.map(f=>'static V '+f.match(/static V (\w+)/)[1]+'(V,const Args&);').join('\n')}\n${functions.join('\n\n')}\nstatic void initializeClasses() {\n${setups.join('\n')}\nR(G(G(E->globals,P_com),P_abowman),P_math)=object({{P_Trig,G(E->globals,P_Trig)}});\nR(G(G(E->globals,P_com),P_abowman),P_graphics)=object({{P_Draw,G(E->globals,P_Draw)}});\n}\n`);
console.log('Generated native C++ behavior, geometry, and property IDs.');
