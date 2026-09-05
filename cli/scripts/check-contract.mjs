import assert from "node:assert/strict";
import {readFile} from "node:fs/promises";
const copy = await readFile(new URL("../docs/api-contract.openapiv3.yaml", import.meta.url));
const source = await readFile(new URL("../../platform/contracts/api-contract.openapiv3.yaml", import.meta.url));
assert.deepEqual(copy, source, "Refresh the CLI's reviewed API copy from the owning platform contract.");
console.log("CLI API copy matches the product contract.");
