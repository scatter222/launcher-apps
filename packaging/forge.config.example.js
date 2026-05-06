// forge.config.example.js
//
// Reference Electron Forge config for an app that derives from libvirt-ui
// and ships as an RPM. Solves two RPM problems that hit when you install
// two libvirt-ui-derived RPMs side by side:
//
//   1. Build-ID symlink collision -- both RPMs end up shipping
//      /usr/lib/.build-id/<aa>/<bbbbbb...> symlinks pointing at their own
//      copy of the (bit-identical) Electron framework binaries. RPM blocks
//      the second install with:
//        file /usr/lib/.build-id/3f/abc... from install of app-two-1.0
//        conflicts with file from package app-one-1.0
//
//   2. Path collisions when both RPMs were forked from the same template
//      and never had their `name`, `productName`, `bin`, etc. customized.
//
// Both fixes below are independent. Pick one for (1):
//   FIX A  (recommended): write %_build_id_links none to ~/.rpmmacros via
//          the `generateAssets` hook. rpmbuild reads this automatically;
//          no symlinks are generated. Smallest, surest change.
//   FIX B  (alternative): strip --strip-unneeded the binaries before they
//          get packaged. Removes the .note.gnu.build-id ELF section so
//          rpmbuild has nothing to symlink. Side benefit: smaller RPMs.
//
// Use FIX A unless you have a reason to keep the build-id metadata at
// build time (some debuginfo workflows). Don't apply both at once -- it's
// fine, just redundant.

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execSync } = require('node:child_process');

// ---------------------------------------------------------------------------
// EDIT THESE for each app. The two apps you fork from libvirt-ui MUST have
// distinct values here, or rpm -i will reject the second install for path
// collisions even after the build-id fix.
// ---------------------------------------------------------------------------
const APP = {
  name: 'app-one',                 // RPM Name:; install path /usr/lib/app-one
  productName: 'App One',          // human-readable, used in .desktop file
  executableName: 'app-one',       // binary name inside the RPM
  bin: 'app-one',                  // launcher symlink under /usr/bin/
  description: 'App One -- libvirt UI fork for X.',
  productDescription:
    'Long-form description shown by `rpm -qi app-one`.',
  version: '1.0.0',
  license: 'MIT',
  homepage: 'https://example.internal/app-one',
  categories: ['Utility', 'System'],
};

// ---------------------------------------------------------------------------
// FIX A: write %_build_id_links none to ~/.rpmmacros. Idempotent.
// rpmbuild (invoked by @electron-forge/maker-rpm via electron-installer-redhat)
// reads this file automatically.
// ---------------------------------------------------------------------------
function disableRpmBuildIdLinks() {
  const file = path.join(os.homedir(), '.rpmmacros');
  const line = '%_build_id_links none\n';
  const current = fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : '';
  if (!current.includes('_build_id_links')) {
    fs.appendFileSync(file, line);
    console.log(`[forge] wrote %_build_id_links none to ${file}`);
  }
}

// ---------------------------------------------------------------------------
// FIX B (alternative): strip Electron's ELF binaries during packaging.
// Erases .note.gnu.build-id so rpmbuild has nothing to deduplicate.
// `--strip-unneeded` is safe for executables -- it only drops local/debug
// symbols, not anything dynamically resolved at runtime.
// ---------------------------------------------------------------------------
function stripBinariesAfterCopy(buildPath, _electronVersion, platform, _arch, cb) {
  if (platform !== 'linux') return cb();
  try {
    execSync(
      `find "${buildPath}" -type f -executable ` +
      `-exec sh -c 'file "$1" 2>/dev/null | grep -q ELF && ` +
      `strip --strip-unneeded "$1" 2>/dev/null || true' _ {} \\;`,
      { stdio: 'inherit' }
    );
  } catch (err) {
    console.warn('[forge] strip pass failed (non-fatal):', err.message);
  }
  cb();
}

module.exports = {
  packagerConfig: {
    name: APP.executableName,
    executableName: APP.executableName,
    // Uncomment to use FIX B instead of (or in addition to) FIX A:
    // afterCopy: [stripBinariesAfterCopy],
  },

  hooks: {
    // FIX A runs once before any maker. Idempotent across runs and apps.
    generateAssets: async () => {
      disableRpmBuildIdLinks();
    },
  },

  makers: [
    {
      name: '@electron-forge/maker-rpm',
      config: {
        options: {
          name: APP.name,
          productName: APP.productName,
          genericName: APP.productName,
          description: APP.description,
          productDescription: APP.productDescription,
          version: APP.version,
          license: APP.license,
          homepage: APP.homepage,
          categories: APP.categories,
          bin: APP.bin,
        },
      },
    },
  ],
};
