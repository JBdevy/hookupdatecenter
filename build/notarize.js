// Hook Center macOS notarization helper.
// Assinatura acontece pelo electron-builder quando existir certificado Developer ID
// via CSC_LINK/CSC_KEY_PASSWORD ou certificado no keychain.
// A notarização é opcional e só roda se as variáveis da Apple estiverem configuradas.

const { notarize } = require('@electron/notarize');

exports.default = async function notarizing(context) {
  const { electronPlatformName, appOutDir, packager } = context;
  if (electronPlatformName !== 'darwin') return;

  const appId = packager.appInfo.appId;
  const appName = packager.appInfo.productFilename;
  const appPath = `${appOutDir}/${appName}.app`;

  const appleId = process.env.APPLE_ID;
  const appleIdPassword = process.env.APPLE_APP_SPECIFIC_PASSWORD || process.env.APPLE_ID_PASSWORD;
  const teamId = process.env.APPLE_TEAM_ID;

  if (!appleId || !appleIdPassword || !teamId) {
    console.log('[notarize] Variáveis Apple não configuradas. App será apenas assinado.');
    return;
  }

  console.log(`[notarize] Enviando ${appPath} para notarização...`);
  await notarize({
    appBundleId: appId,
    appPath,
    appleId,
    appleIdPassword,
    teamId
  });
};
