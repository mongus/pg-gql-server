FROM node:22-alpine

USER node
WORKDIR /home/node

RUN npm i postgraphile@beta

ENV GRAPHQL_PORT=5678

CMD ["npx", "postgraphile"]

HEALTHCHECK --interval=10s --timeout=5s --start-period=1s --retries=3 \
  CMD wget --quiet \
    --header="Content-Type: application/json" \
    --post-data='{"query": "{ __typename }"}' \
    -O - http://localhost:${GRAPHQL_PORT}/graphql | grep -q '"data"'
