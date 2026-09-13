'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const root = path.join(__dirname, '..', 'src');
const html = fs.readFileSync(path.join(root, 'index.html'), 'utf8');
const renderer = fs.readFileSync(path.join(root, 'renderer.js'), 'utf8');
const main = fs.readFileSync(path.join(root, 'main.js'), 'utf8');

assert.match(html, /id="accountLoginDocument"/);
assert.match(html, /id="devicesDocumentInput"/);
assert.doesNotMatch(html, /licenseEmailCodeModal/);
assert.match(renderer, /performAccountLogin\(email, document\)/);
assert.match(renderer, /!\[11, 14\]\.includes\(cleanDocument\.length\)/);
assert.doesNotMatch(renderer, /runEmailVerifiedLicenseAction|promptLicenseEmailCode/);
assert.match(main, /const hasStoredLogin = Boolean\(storedDeviceLoginEmail \|\| license\.email\)/);
assert.match(main, /const deviceLoggedIn = !explicitlyLoggedOut && hasStoredLogin/);
assert.doesNotMatch(main, /accountSessionToken|ensureStoredAccountSession/);
assert.doesNotMatch(main, /verificationCode:String\(payload/);

const formatterStart = renderer.indexOf('function loginDocumentDigits');
const formatterEnd = renderer.indexOf('function setupLoginDocumentInput', formatterStart);
assert.notEqual(formatterStart, -1);
assert.notEqual(formatterEnd, -1);
const formatterContext = {};
vm.runInNewContext(`${renderer.slice(formatterStart, formatterEnd)}\nthis.formatLoginDocument = formatLoginDocument;`, formatterContext);
assert.equal(formatterContext.formatLoginDocument('07843249567'), '078.432.495-67');
assert.equal(formatterContext.formatLoginDocument('04252011000110'), '04.252.011/0001-10');

console.log('HOOK_CENTER_DOCUMENT_AUTH_OK: CPF/CNPJ funcionam, o login local persiste até Sair e não há código nem sessão nova.');
