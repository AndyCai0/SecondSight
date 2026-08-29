import {
  useEffect,
  useRef,
  useState,
  type PointerEvent as ReactPointerEvent,
  type RefObject,
} from 'react'
import type {
  ArrowAnnotation,
  CircleAnnotation,
  PointerMessage,
  VolunteerOutboundMessage,
} from './contracts'
import { opacityForExpiry } from './annotationTiming'
import { pointToVideoCoordinates, videoFrameBox, type Point } from './geometry'
import { shouldSendPointer } from './pointerThrottle'

type Tool = 'circle' | 'arrow' | 'pointer'
type TimedAnnotation = (CircleAnnotation | ArrowAnnotation) & { expiresAt: number }

interface AnnotationSurfaceProps {
  videoRef: RefObject<HTMLVideoElement | null>
  hasMedia: boolean
  disabled?: boolean
  send(message: VolunteerOutboundMessage): Promise<void>
  log(message: VolunteerOutboundMessage): void
  onSendError(): void
}

export function AnnotationSurface({
  videoRef,
  hasMedia,
  disabled = false,
  send,
  log,
  onSendError,
}: AnnotationSurfaceProps) {
  const containerRef = useRef<HTMLDivElement>(null)
  const canvasRef = useRef<HTMLCanvasElement>(null)
  const [tool, setTool] = useState<Tool>('circle')
  const [annotations, setAnnotations] = useState<TimedAnnotation[]>([])
  const [pointer, setPointer] = useState<(PointerMessage & { expiresAt: number }) | null>(null)
  const [dragStart, setDragStart] = useState<Point | null>(null)
  const [dragEnd, setDragEnd] = useState<Point | null>(null)
  const pointerDown = useRef(false)
  const lastPointerSentAt = useRef(-Infinity)

  useEffect(() => {
    const timer = window.setInterval(() => {
      const now = performance.now()
      setAnnotations((current) => current.filter((item) => item.expiresAt > now))
      setPointer((current) => current && current.expiresAt > now ? current : null)
    }, 200)
    return () => window.clearInterval(timer)
  }, [])

  useEffect(() => {
    const container = containerRef.current
    const canvas = canvasRef.current
    const video = videoRef.current
    if (!container || !canvas || !video) return

    const draw = () => {
      const containerBox = container.getBoundingClientRect()
      const pixelRatio = window.devicePixelRatio || 1
      const width = Math.max(1, Math.round(containerBox.width * pixelRatio))
      const height = Math.max(1, Math.round(containerBox.height * pixelRatio))
      if (canvas.width !== width || canvas.height !== height) {
        canvas.width = width
        canvas.height = height
      }
      const context = canvas.getContext('2d')
      if (!context) return
      context.setTransform(pixelRatio, 0, 0, pixelRatio, 0, 0)
      context.clearRect(0, 0, containerBox.width, containerBox.height)

      const frame = videoFrameBox(containerBox, {
        width: video.videoWidth || 16,
        height: video.videoHeight || 9,
      })
      if (!frame) return
      const left = frame.left - containerBox.left
      const top = frame.top - containerBox.top
      const toCanvas = (point: Point) => ({
        x: left + point.x * frame.width,
        y: top + point.y * frame.height,
      })

      context.lineWidth = 4
      context.lineCap = 'round'
      context.lineJoin = 'round'
      const now = performance.now()
      for (const annotation of annotations) {
        context.globalAlpha = opacityForExpiry(annotation.expiresAt, now)
        context.strokeStyle = '#ff6b4a'
        context.fillStyle = '#ff6b4a'
        if (annotation.type === 'annotate.circle') {
          const center = toCanvas(annotation)
          context.beginPath()
          context.arc(center.x, center.y, annotation.r * Math.min(frame.width, frame.height), 0, 2 * Math.PI)
          context.stroke()
        } else {
          drawArrow(
            context,
            toCanvas({ x: annotation.x1, y: annotation.y1 }),
            toCanvas({ x: annotation.x2, y: annotation.y2 }),
          )
        }
      }
      context.globalAlpha = 1

      if (dragStart && dragEnd && tool === 'arrow') {
        context.strokeStyle = 'rgba(255, 107, 74, 0.65)'
        context.fillStyle = 'rgba(255, 107, 74, 0.65)'
        drawArrow(context, toCanvas(dragStart), toCanvas(dragEnd))
      }

      if (pointer) {
        const point = toCanvas(pointer)
        context.fillStyle = '#44d7d2'
        context.beginPath()
        context.arc(point.x, point.y, 8, 0, 2 * Math.PI)
        context.fill()
      }
    }

    draw()
    const observer = typeof ResizeObserver === 'undefined' ? null : new ResizeObserver(draw)
    observer?.observe(container)
    video.addEventListener('loadedmetadata', draw)
    return () => {
      observer?.disconnect()
      video.removeEventListener('loadedmetadata', draw)
    }
  }, [annotations, dragEnd, dragStart, pointer, tool, videoRef])

  function normalizedPoint(event: ReactPointerEvent<HTMLCanvasElement>): Point | null {
    const video = videoRef.current
    const container = containerRef.current
    if (!video || !container) return null
    return pointToVideoCoordinates(
      { x: event.clientX, y: event.clientY },
      container.getBoundingClientRect(),
      { width: video.videoWidth || 16, height: video.videoHeight || 9 },
    )
  }

  function transmit(message: VolunteerOutboundMessage, audit: boolean): void {
    void send(message).catch(onSendError)
    if (audit) log(message)
  }

  function handlePointerDown(event: ReactPointerEvent<HTMLCanvasElement>): void {
    if (disabled) return
    const point = normalizedPoint(event)
    if (!point) return
    event.currentTarget.setPointerCapture(event.pointerId)
    pointerDown.current = true
    setDragStart(point)
    setDragEnd(point)
    if (tool === 'pointer') sendPointer(point, event.timeStamp)
  }

  function handlePointerMove(event: ReactPointerEvent<HTMLCanvasElement>): void {
    if (!pointerDown.current || disabled) return
    const point = normalizedPoint(event)
    if (!point) return
    setDragEnd(point)
    if (tool === 'pointer') sendPointer(point, event.timeStamp)
  }

  function handlePointerUp(event: ReactPointerEvent<HTMLCanvasElement>): void {
    if (!pointerDown.current || disabled) return
    pointerDown.current = false
    const end = normalizedPoint(event)
    const start = dragStart
    setDragStart(null)
    setDragEnd(null)
    if (!start || !end) return

    const now = performance.now()
    if (tool === 'circle') {
      const message: CircleAnnotation = {
        v: 1,
        type: 'annotate.circle',
        id: crypto.randomUUID(),
        x: end.x,
        y: end.y,
        r: 0.05,
        ttl_ms: 6000,
      }
      setAnnotations((current) => [...current, { ...message, expiresAt: now + message.ttl_ms }])
      transmit(message, true)
    }
    if (tool === 'arrow' && Math.hypot(end.x - start.x, end.y - start.y) >= 0.01) {
      const message: ArrowAnnotation = {
        v: 1,
        type: 'annotate.arrow',
        id: crypto.randomUUID(),
        x1: start.x,
        y1: start.y,
        x2: end.x,
        y2: end.y,
        ttl_ms: 6000,
      }
      setAnnotations((current) => [...current, { ...message, expiresAt: now + message.ttl_ms }])
      transmit(message, true)
    }
  }

  function sendPointer(point: Point, now: number): void {
    if (!shouldSendPointer(lastPointerSentAt.current, now)) return
    lastPointerSentAt.current = now
    const message: PointerMessage = { v: 1, type: 'pointer', ...point }
    setPointer({ ...message, expiresAt: now + 140 })
    transmit(message, false)
  }

  function clearAnnotations(): void {
    const message: VolunteerOutboundMessage = { v: 1, type: 'annotate.clear' }
    setAnnotations([])
    setPointer(null)
    transmit(message, true)
  }

  return (
    <section className="assist-surface" aria-label="远程协助画面">
      <div className="video-stage" ref={containerRef}>
        <video ref={videoRef} autoPlay playsInline aria-label="长辈共享的屏幕" />
        <canvas
          ref={canvasRef}
          aria-label="标注画布"
          onPointerDown={handlePointerDown}
          onPointerMove={handlePointerMove}
          onPointerUp={handlePointerUp}
          onPointerCancel={() => {
            pointerDown.current = false
            setDragStart(null)
            setDragEnd(null)
          }}
        />
        {!hasMedia && <div className="waiting-media">等待长辈分享电脑画面…</div>}
      </div>
      <div className="annotation-toolbar" role="toolbar" aria-label="标注工具">
        <button className={tool === 'circle' ? 'selected' : ''} onClick={() => setTool('circle')} disabled={disabled}>
          <span aria-hidden="true">◯</span> 圈出位置
        </button>
        <button className={tool === 'arrow' ? 'selected' : ''} onClick={() => setTool('arrow')} disabled={disabled}>
          <span aria-hidden="true">↗</span> 画箭头
        </button>
        <button className={tool === 'pointer' ? 'selected' : ''} onClick={() => setTool('pointer')} disabled={disabled}>
          <span aria-hidden="true">●</span> 激光笔
        </button>
        <button onClick={clearAnnotations} disabled={disabled}>
          清除标注
        </button>
      </div>
    </section>
  )
}

function drawArrow(context: CanvasRenderingContext2D, start: Point, end: Point): void {
  const angle = Math.atan2(end.y - start.y, end.x - start.x)
  const headLength = 15
  context.beginPath()
  context.moveTo(start.x, start.y)
  context.lineTo(end.x, end.y)
  context.lineTo(
    end.x - headLength * Math.cos(angle - Math.PI / 6),
    end.y - headLength * Math.sin(angle - Math.PI / 6),
  )
  context.moveTo(end.x, end.y)
  context.lineTo(
    end.x - headLength * Math.cos(angle + Math.PI / 6),
    end.y - headLength * Math.sin(angle + Math.PI / 6),
  )
  context.stroke()
}
