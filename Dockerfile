# ── 构建阶段 ──────────────────────────────────────────────────────────────────
# 仅用于编译 TypeScript 和准备前端资源（不处理原生模块）
FROM --platform=$BUILDPLATFORM node:18-alpine AS builder

WORKDIR /home

COPY package.json yarn.lock ./

# 安装依赖（仅用于 tsc 编译，不需要 node-gyp 工具链）
RUN yarn install --ignore-engines

# 复制源码并编译 TypeScript / 前端
COPY . .
RUN rm -rf vender/cloud189-sdk/docs vender/cloud189-sdk/example \
           vender/cloud189-sdk/test vender/cloud189-sdk/.git \
           vender/cloud189-sdk/.vscode vender/cloud189-sdk/.github
RUN node scripts/copy-vendor.js && npx tsc && cp -r src/public dist/public
RUN find dist/public/vendor -name "*.js.map" -delete 2>/dev/null; true

# ── 生产阶段 ──────────────────────────────────────────────────────────────────
# 在目标平台（armv7）上运行，编译原生模块
FROM node:18-alpine AS production

WORKDIR /home

ARG APP_VERSION=dev

# 安装运行时依赖 + 原生编译工具链（armv7 需要现场编译 better-sqlite3）
RUN apk add --no-cache ca-certificates tzdata python3 make g++ && \
    ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime && \
    echo "Asia/Shanghai" > /etc/timezone && \
    mkdir -p /home/data /home/strm && \
    chown -R node:node /home

# 复制 package.json 并在目标平台安装生产依赖（better-sqlite3 会编译出 armv7 原生模块）
COPY package.json yarn.lock ./
RUN yarn install --production --ignore-engines && \
    yarn cache clean && \
    # 清理编译后的开发工具链，减小镜像
    apk del python3 make g++ && \
    rm -rf /var/cache/apk/* && \
    # 清理运行时不需要的文件
    find node_modules -name "*.d.ts" -delete && \
    find node_modules -name "*.d.ts.map" -delete && \
    find node_modules -name "*.js.map" -delete && \
    rm -rf node_modules/typeorm/browser && \
    find node_modules \( -name "README*" -o -name "CHANGELOG*" \) -not -path "*/bin/*" -delete 2>/dev/null; true

# 复制 builder 阶段编译好的 JS 和前端资源
COPY --from=builder /home/dist ./dist
COPY --from=builder /home/src/public ./dist/public

ENV TZ=Asia/Shanghai
ENV NODE_ENV=production
ENV APP_VERSION=${APP_VERSION}

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD wget -qO- http://127.0.0.1:3000/api/health || exit 1

USER node

VOLUME ["/home/data", "/home/strm"]
EXPOSE 3000
CMD ["npm", "run", "start:prod"]
