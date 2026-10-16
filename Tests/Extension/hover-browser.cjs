// Run with Node + Playwright available on NODE_PATH. Uses an isolated browser profile.
const {chromium} = require('playwright');
const fs = require('node:fs');
const assert = require('node:assert/strict');
(async () => {
 const browser = await chromium.launch({executablePath:process.env.QD_BROWSER_BINARY || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true});
 try {
  const page = await browser.newPage({viewport:{width:1000,height:700}});
  await page.route('https://quickdown.test/**', r=>r.fulfill({contentType:'text/html',body:'<style>body{margin:0}video{position:absolute;left:100px;top:50px;width:800px;height:500px;background:#222}#cover{position:absolute;left:400px;top:200px;width:200px;height:150px}#link{position:absolute;left:500px;top:600px}</style><video src="blob:test"></video><div id="cover">Player overlay</div><button id="link" onclick="this.textContent=\'Clicked\'">Page button</button>'}));
  await page.goto('https://quickdown.test/');
  await page.evaluate(()=>{window.chrome={storage:{sync:{get(d,f){f(d);}},onChanged:{addListener(){}}},runtime:{onMessage:{addListener(){}},sendMessage:async()=>({videos:[]})}};});
  await page.addScriptTag({content:fs.readFileSync('Extension/content.js','utf8')});
  const button=page.locator('#qd-hover-btn');
  await page.mouse.move(600,300); await button.waitFor({state:'visible'});
  let box=await button.boundingBox();assert.equal(box.width,28);assert.equal(box.height,28);assert.ok(box.x<100,'entry outside video');
  await page.waitForTimeout(80);await page.mouse.move(890,540);assert.ok(await button.isVisible(),'far corner still reveals entry');
  await page.waitForTimeout(80);await page.mouse.move(80,110);assert.ok(await button.isVisible(),'external button reachable');
  await button.waitFor({state:'hidden',timeout:4500});
  await page.mouse.move(500,300);await button.waitFor({state:'visible'});
  await page.locator('#link').click();assert.equal(await page.locator('#link').textContent(),'Clicked');assert.equal(await button.isVisible(),false,'page controls remain usable');
  console.log('PASS: actual Chrome layout, video-center/overlay hover, 28px size, external entry reachability, idle hide and page click');
 } finally {await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
