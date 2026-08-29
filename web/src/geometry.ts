export interface Point {
  x: number
  y: number
}

export interface Box {
  left: number
  top: number
  width: number
  height: number
}

export interface Size {
  width: number
  height: number
}

export function pointToVideoCoordinates(
  point: Point,
  container: Box,
  video: Size,
): Point | null {
  const rendered = videoFrameBox(container, video)
  if (!rendered) return null

  if (
    point.x < rendered.left || point.x > rendered.left + rendered.width ||
    point.y < rendered.top || point.y > rendered.top + rendered.height
  ) {
    return null
  }

  return {
    x: (point.x - rendered.left) / rendered.width,
    y: (point.y - rendered.top) / rendered.height,
  }
}

export function videoFrameBox(container: Box, video: Size): Box | null {
  if (container.width <= 0 || container.height <= 0 || video.width <= 0 || video.height <= 0) {
    return null
  }

  const scale = Math.min(container.width / video.width, container.height / video.height)
  const width = video.width * scale
  const height = video.height * scale
  return {
    left: container.left + (container.width - width) / 2,
    top: container.top + (container.height - height) / 2,
    width,
    height,
  }
}
