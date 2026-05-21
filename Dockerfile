ARG NODE_IMAGE_VERSION="22-alpine"

# Install dependencies only when needed
FROM node:${NODE_IMAGE_VERSION} AS deps
# Check https://github.com/nodejs/docker-node/tree/b4117f9333da4138b03a546ec926ef50a31506c3#nodealpine to understand why libc6-compat might be needed.
RUN apk add --no-cache libc6-compat
WORKDIR /app
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
RUN npm install -g pnpm
RUN pnpm install --frozen-lockfile

# Rebuild the source code only when needed
FROM node:${NODE_IMAGE_VERSION} AS builder
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .
COPY docker/proxy.ts ./src

# Hardcoded for kunbord.com/umami path proxy (see Kunbord/docs/umami-railway.md)
ENV BASE_PATH=/umami
ENV NEXT_TELEMETRY_DISABLED=1
ENV DATABASE_URL="postgresql://user:pass@localhost:5432/dummy"

RUN npm run build-docker

# Production image, copy all the files and run next
FROM node:${NODE_IMAGE_VERSION} AS runner
WORKDIR /app

ARG NODE_OPTIONS

ENV NODE_ENV=production
ENV NEXT_TELEMETRY_DISABLED=1
ENV NODE_OPTIONS=$NODE_OPTIONS
# Railway / Docker: non-interactive pnpm (avoids ERR_PNPM_ABORTED_REMOVE_MODULES_DIR_NO_TTY)
ENV CI=true

RUN addgroup --system --gid 1001 nodejs
RUN adduser --system --uid 1001 nextjs
RUN set -x \
    && apk add --no-cache curl \
    && npm install -g pnpm

COPY --from=builder /app/public ./public
COPY --from=builder /app/prisma ./prisma
COPY --from=builder /app/prisma.config.ts ./prisma.config.ts
COPY --from=builder /app/scripts ./scripts
COPY --from=builder /app/generated ./generated
COPY --from=builder /app/.next/standalone ./
COPY --from=builder /app/.next/static ./.next/static

# Script deps for check-db.js (must run after standalone — earlier pnpm add is overwritten)
COPY pnpm-workspace.yaml ./
RUN pnpm add dotenv chalk semver \
    prisma@7.8.0 \
    @prisma/client@7.8.0 \
    @prisma/adapter-pg@7.8.0

RUN chown -R nextjs:nodejs /app

USER nextjs

EXPOSE 3000

ENV HOSTNAME=0.0.0.0
ENV PORT=3000

# Do not use `pnpm start-docker` — pnpm 10 re-runs install when package.json ≠ node_modules
CMD ["sh", "-c", "node scripts/check-db.js && node scripts/update-tracker.js && node server.js"]