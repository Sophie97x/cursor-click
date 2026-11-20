'use strict';

const fs = require('node:fs');
const { createServer } = require('./server');

const app = createServer({ headless: false, openBrowser: false, port: 0, refreshGate: process.argv[3] });
const ready = app.listen();

async function shutdown() {
  try {
    await ready;
    await app.close();
  } finally {
    process.exit();
  }
}

process.stdin.resume();
process.stdin.once('end', shutdown);
process.once('SIGTERM', shutdown);

ready.then((url) => {
  fs.writeFileSync(process.argv[2], url, { flag: 'wx' });
}).catch((error) => {
  console.error(error);
  process.exit(1);
});
