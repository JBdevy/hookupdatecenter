const { execFile } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

function run(command, args, options = {}) {
  return new Promise((resolve, reject) => {
    const child = execFile(command, args, { ...options, maxBuffer: 1024 * 1024 * 20 }, (error, stdout, stderr) => {
      if (stdout) process.stdout.write(stdout);
      if (stderr) process.stderr.write(stderr);
      if (error) {
        error.stdout = stdout;
        error.stderr = stderr;
        reject(error);
        return;
      }
      resolve({ stdout, stderr });
    });
    child.stdout && child.stdout.pipe(process.stdout);
    child.stderr && child.stderr.pipe(process.stderr);
  });
}

exports.default = async function notarizeMac(context) {
  if (context.electronPlatformName !== 'darwin') return;

  const appleId = process.env.APPLE_ID;
  const applePassword = process.env.APPLE_APP_SPECIFIC_PASSWORD;
  const teamId = process.env.APPLE_TEAM_ID;

  if (!appleId || !applePassword || !teamId) {
    throw new Error('Notarização macOS bloqueada: configure APPLE_ID, APPLE_APP_SPECIFIC_PASSWORD e APPLE_TEAM_ID nos GitHub Secrets.');
  }

  const appName = context.packager.appInfo.productFilename;
  const appPath = path.join(context.appOutDir, `${appName}.app`);

  if (!fs.existsSync(appPath)) {
    throw new Error(`App macOS não encontrado para notarização: ${appPath}`);
  }

  const zipPath = path.join(os.tmpdir(), `${appName.replace(/\s+/g, '-')}-${Date.now()}-notary.zip`);

  console.log(`\n[macOS] Preparando app para notarização: ${appPath}`);
  await run('ditto', ['-c', '-k', '--keepParent', appPath, zipPath]);

  console.log('\n[macOS] Enviando app assinado para notarização Apple...');
  await run('xcrun', [
    'notarytool',
    'submit',
    zipPath,
    '--apple-id',
    appleId,
    '--password',
    applePassword,
    '--team-id',
    teamId,
    '--wait'
  ]);

  console.log('\n[macOS] Gravando ticket de notarização no .app...');
  await run('xcrun', ['stapler', 'staple', appPath]);

  console.log('\n[macOS] Conferindo assinatura do .app...');
  await run('codesign', ['--verify', '--deep', '--strict', '--verbose=2', appPath]);

  console.log('\n[macOS] Conferindo Gatekeeper do .app...');
  await run('spctl', ['-a', '-vvv', '-t', 'exec', appPath]);

  try {
    fs.unlinkSync(zipPath);
  } catch (_) {}
};
