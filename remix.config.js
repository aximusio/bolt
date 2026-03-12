/**
 * Remix config forcing Node CJS server build.
 * This ensures the server bundle targets Node (CJS) instead of Cloudflare.
 */
/** @type {import('@remix-run/dev').AppConfig} */
module.exports = {
  serverBuildTarget: 'node-cjs',
  serverModuleFormat: 'cjs',
};
