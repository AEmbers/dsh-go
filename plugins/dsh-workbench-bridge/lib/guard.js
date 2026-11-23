/**
 * @file 路由安全守卫（Fail-closed）：对接 DSH 宿主的 connection 服务校验请求来源。
 */

/**
 * 解析写入或读取所需的请求合法性检查。
 * 当宿主未提供 connection 服务时拒绝写操作（503），存在 rejection 时透传状态码。
 *
 * @param {object} ctx Cordis 插件上下文
 * @param {{ requireConnection?: boolean }} [options]
 * @returns {(req: unknown) => { status: number, body: { code: string, message: string } } | null}
 */
export function makeBridgeGuard(ctx, options = {}) {
  const { requireConnection = true } = options;
  return function checkRequest(req) {
    const connection = typeof ctx?.get === 'function' ? ctx.get('connection') : undefined;
    if (connection === undefined) {
      if (!requireConnection) return null;
      return {
        status: 503,
        body: {
          code: 'unavailable',
          message: 'connection service is not available; workbench bridge routes are closed',
        },
      };
    }
    if (typeof connection.requestRejection === 'function') {
      const rejection = connection.requestRejection(req);
      if (rejection) {
        const status = Number.isInteger(rejection.status) ? rejection.status : 403;
        return {
          status,
          body: {
            code: String(rejection.code || 'forbidden'),
            message: String(rejection.message || 'request rejected by host connection guard'),
          },
        };
      }
    }
    return null;
  };
}
