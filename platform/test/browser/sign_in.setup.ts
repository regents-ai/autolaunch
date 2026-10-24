import {test} from "./support/test"
import {signedIn} from "./support/person"

// The walk's person signs in through the site's own sign-in step, which the browser
// test server answers with its stand-in for Privy (Autolaunch.TestPrivyVerifier),
// and the walk's signed-in checks start from the cookie it leaves.
test("the walk's person signs in", async ({page}) => {
  await page.goto("/")
  const signedInStatus = await page.evaluate(async () => {
    const {csrf_token} = await (await fetch("/auth/csrf")).json()
    const response = await fetch("/auth/privy/session", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-csrf-token": csrf_token,
        authorization: "Bearer valid",
        "privy-id-token": "valid-identity",
      },
      body: "{}",
    })
    return response.status
  })
  test.expect(signedInStatus).toBe(200)
  await page.context().storageState({path: signedIn.storageState})
})
