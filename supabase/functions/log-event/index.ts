import { runFunction } from '../_shared/runtime.ts'

export default {
  fetch: (request: Request) => runFunction('log-event', request),
}
