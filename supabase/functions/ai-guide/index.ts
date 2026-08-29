import { runFunction } from '../_shared/runtime.ts'

export default {
  fetch: (request: Request) => runFunction('ai-guide', request),
}
