# Build stage
FROM public.ecr.aws/docker/library/node:20-alpine AS build-stage
WORKDIR /app
COPY frontend/package*.json ./
RUN npm install
COPY frontend/ .
RUN npm run build

# Production stage
FROM public.ecr.aws/nginx/nginx:stable-alpine AS production-stage
# Remove default nginx config
RUN rm /etc/nginx/conf.d/default.conf
# Copy custom config
COPY nginx.conf /etc/nginx/conf.d/default.conf
# Copy built assets
COPY --from=build-stage /app/dist /usr/share/nginx/html
EXPOSE 3000
CMD ["nginx", "-g", "daemon off;"]
