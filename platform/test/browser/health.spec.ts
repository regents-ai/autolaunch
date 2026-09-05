import {expect, test} from "@playwright/test"

test("the health check answers ok", async ({request}) => {
  const response = await request.get("/healthz")

  expect(response.status()).toBe(200)
  expect(await response.text()).toBe("ok")
})
