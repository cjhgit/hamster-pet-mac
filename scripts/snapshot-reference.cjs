// Development-only visual reference. The native application never loads this.
const path=require('path');
const reference=path.resolve(process.argv[2]||'../hamster-html');
const {chromium}=require(path.join(reference,'node_modules/playwright'));
(async()=>{
 const browser=await chromium.launch({headless:true,executablePath:process.env.CHROME_PATH||path.join(require('os').homedir(),'Library/Caches/ms-playwright/chromium-1217/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing')});
 try {
  const page=await browser.newPage({viewport:{width:742,height:605}});
  await page.addInitScript(()=>{let seed=11042;Math.random=()=>{seed=(seed*1664525+1013904223)>>>0;return seed/4294967296;};window.requestAnimationFrame=()=>0;});
  await page.goto(require('url').pathToFileURL(path.join(reference,'index.html')).href);
  await page.evaluate(async()=>{hamsterApp.paused=true;await document.fonts.ready;hamsterApp.render();});
  await page.screenshot({path:'/private/tmp/hamster-reference-window.png'});
 } finally { await browser.close(); }
})().catch(e=>{console.error(e);process.exit(1)});
