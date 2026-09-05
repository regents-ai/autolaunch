#!/usr/bin/env node
import {readFileSync} from "node:fs";
import {run} from "../src/cli.js";
import {commands, notes} from "../src/commands.js";
const {version} = JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8"));
const result = await run({product: "autolaunch", version, defaultOrigin: "https://autolaunch.sh", commands, notes});
if (result !== undefined) process.stdout.write(JSON.stringify(result) + "\n");
