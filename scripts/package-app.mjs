/*
 * Copyright 2026 Adam Cox
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

/**
 * CI only: `node scripts/package-app.mjs <out-dir>` after `swift build -c release`.
 *
 * Assembles <out-dir>/Meetey.app with the same code install uses, signs it with
 * the Developer ID identity in $KEYCHAIN (timestamped, for notarization), and
 * checks the result is what installSignedApp will accept. Notarizing and zipping
 * happen in the workflow.
 */

import { join } from "path";
import { readFileSync } from "fs";
import { APP_ID, TEAM_ID, assembleApp, signApp, signatureInfo } from "../cli/app-bundle.js";

const out = process.argv[2];
const keychain = process.env.KEYCHAIN;
if (!out || !keychain) {
  console.error("usage: KEYCHAIN=<path> node scripts/package-app.mjs <out-dir>");
  process.exit(2);
}

const root = join(import.meta.dirname, "..");
const version = JSON.parse(readFileSync(join(root, "package.json"), "utf8")).version;
const appBundle = join(out, "Meetey.app");

assembleApp({
  builtBinary: join(root, "meetey-capture", ".build", "release", "meetey-capture"),
  appBundle,
  plistTemplate: join(root, "meetey-capture", "Info.plist"),
  version,
});
signApp({
  appBundle,
  entitlements: join(root, "meetey-capture", "entitlements.plist"),
  identity: "Developer ID Application",
  keychain,
  timestamp: true,
});

const signature = signatureInfo(appBundle);
if (!signature || signature.identifier !== APP_ID || signature.adhoc || !signature.teamId) {
  console.error(`Meetey.app did not sign as expected: ${JSON.stringify(signature)}`);
  process.exit(1);
}
if (TEAM_ID && signature.teamId !== TEAM_ID) {
  console.error(`Signed by team ${signature.teamId}, but install only trusts ${TEAM_ID} (TEAM_ID in cli/app-bundle.js)`);
  process.exit(1);
}
console.log(`Signed ${appBundle} v${version} as ${signature.identifier}, team ${signature.teamId}`);
