import { createProductionDependencies } from './dependencies.ts'
import {
  type EdgeDependencies,
  type EdgeFunctionName,
  handleEdgeRequest,
  jsonResponse,
  preflightResponse,
} from './handler.ts'

type DependenciesFactory = () => EdgeDependencies
type ErrorReporter = (error: unknown) => void

export async function runFunction(
  functionName: EdgeFunctionName,
  request: Request,
  createDependencies: DependenciesFactory = createProductionDependencies,
  reportError: ErrorReporter = console.error,
): Promise<Response> {
  if (request.method === 'OPTIONS') return preflightResponse()
  try {
    return await handleEdgeRequest(functionName, request, createDependencies())
  } catch (error) {
    reportError(error)
    return jsonResponse({ error: 'Internal server error' }, 500)
  }
}
