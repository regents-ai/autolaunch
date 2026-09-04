import {expect, it, vi} from "vitest"

import {composeHooks} from "../js/hook_composition"

it("keeps Ash behavior active while composing a Design hook", () => {
  const ashMounted = vi.fn()
  const ashUpdated = vi.fn()
  const designMounted = vi.fn()
  const hook = composeHooks(
    {mounted: ashMounted, updated: ashUpdated},
    {mounted: designMounted},
  )
  const context = {name: "shell"}

  hook.mounted?.call(context, "ready")
  hook.updated?.call(context)

  expect(ashMounted).toHaveBeenCalledWith("ready")
  expect(designMounted).toHaveBeenCalledWith("ready")
  expect(ashUpdated).toHaveBeenCalledOnce()
  expect(ashMounted.mock.instances[0]).toBe(context)
})

it("runs Ash, shell motion, and voxel delight exactly once for every lifecycle", () => {
  const calls: string[] = []
  const lifecycle = (owner: string) => ({
    mounted: vi.fn(() => calls.push(`${owner}:mounted`)),
    updated: vi.fn(() => calls.push(`${owner}:updated`)),
    destroyed: vi.fn(() => calls.push(`${owner}:destroyed`)),
  })
  const host = lifecycle("host")
  const motion = lifecycle("motion")
  const voxel = lifecycle("voxel")
  const hook = composeHooks(host, motion, voxel)
  const context = {name: "shell"}

  hook.mounted?.call(context)
  hook.updated?.call(context)
  hook.destroyed?.call(context)

  expect(calls).toEqual([
    "host:mounted",
    "motion:mounted",
    "voxel:mounted",
    "host:updated",
    "motion:updated",
    "voxel:updated",
    "host:destroyed",
    "motion:destroyed",
    "voxel:destroyed",
  ])
  for (const owner of [host, motion, voxel]) {
    expect(owner.mounted).toHaveBeenCalledOnce()
    expect(owner.updated).toHaveBeenCalledOnce()
    expect(owner.destroyed).toHaveBeenCalledOnce()
    expect(owner.mounted.mock.instances[0]).toBe(context)
  }
})
