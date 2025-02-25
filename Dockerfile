# use the same node version which you used during dev
FROM node:20-alpine
WORKDIR /code/
ADD package.json package-lock.json /code/
RUN npm ci  
ADD . /code/
RUN --mount=type=cache,target=/tmp npx tsx bundleNow.ts
CMD ["npm", "run", "startLive"]