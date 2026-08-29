import { describe, expect, it } from 'vitest'
import { pointToVideoCoordinates, videoFrameBox } from './geometry'

describe('video annotation geometry', () => {
  it('subtracts letterbox bars before normalizing pointer coordinates', () => {
    const point = pointToVideoCoordinates(
      { x: 500, y: 300 },
      { left: 0, top: 0, width: 1000, height: 600 },
      { width: 1600, height: 900 },
    )

    expect(point).toEqual({ x: 0.5, y: 0.5 })
    expect(pointToVideoCoordinates(
      { x: 500, y: 4 },
      { left: 0, top: 0, width: 1000, height: 600 },
      { width: 1600, height: 900 },
    )).toBeNull()
  })

  it('returns the rendered video box inside a letterboxed container', () => {
    expect(videoFrameBox(
      { left: 10, top: 20, width: 1000, height: 600 },
      { width: 1600, height: 900 },
    )).toEqual({ left: 10, top: 38.75, width: 1000, height: 562.5 })
  })
})
