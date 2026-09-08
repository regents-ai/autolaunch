import {defineConfig} from "vitest/config"

export default defineConfig({
  test: {
    include: ["core_tests/js/**/*.test.ts"],
  },
})
