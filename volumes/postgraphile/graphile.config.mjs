import jwt from 'jsonwebtoken';

import { PostGraphileAmberPreset } from "postgraphile/presets/amber";
import { makePgService } from "@dataplan/pg/adaptors/pg";

import { PgSimplifyInflectionPreset } from "@graphile/simplify-inflection";
import { PgOmitArchivedPlugin } from '@graphile-contrib/pg-omit-archived';

function fatalError(message) {
    console.error(message);
    process.exit(1);
}

if (/REPLACE/.test(process.env.SUPERUSER_DATABASE_URL))
    fatalError("Please change the POSTGRES_PASSWORD entry in .env");

if (/REPLACE/.test(process.env.DATABASE_URL))
    fatalError("Please change the POSTGRAPHILE_PASSWORD entry in .env");

if (/REPLACE/.test(process.env.JWT_SECRET))
    fatalError("Please change the JWT_SECRET entry in .env");

const stage = process.env.STAGE;
const live = stage === 'production';

const stars = '*'.repeat(stage.length + 11);
console.log(`

${stars}
* Stage: ${stage.toUpperCase()} *
${stars}

`);

async function authorize(ctx, args) {
    const authorization = ctx?.node?.req?.headers?.authorization;

    const pgSettings = {
        ...args.contextValue?.pgSettings,
        role: 'anonymous'
    };

    if (typeof authorization === 'string' && authorization.startsWith('Bearer ')) {
        const token = authorization.slice(7);

        try {
            const claims = await new Promise((resolve, reject) => {
                jwt.verify(
                    token,
                    process.env.JWT_SECRET,
                    {
                        algorithms: ["HS256", "HS384"],
                        audience: "postgraphile",
                        complete: false,
                    },
                    (err, claims) => {
                        if (err) {
                            err.statusCode = 401;
                            reject(err);
                        } else if (!claims || typeof claims === "string") {
                            reject(
                                Object.assign(new Error("Invalid JWT payload"), {
                                    statusCode: 401,
                                }),
                            );
                        } else {
                            resolve(claims);
                        }
                    }
                );
            });

            if (claims.role) {
                pgSettings.role = claims.role;
                pgSettings[`jwt.claims.uid`] = claims.uid;
            }
        } catch (e) {
            console.error(e);
        }
    }

    return { pgSettings };
}

/** @type {GraphileConfig.Preset} */
const preset = {
    extends: [
        PostGraphileAmberPreset,
        PgSimplifyInflectionPreset,
    ],

    plugins: [
        PgOmitArchivedPlugin,
    ],

    schema: {
        dontSwallowErrors: true,
        pgJwtSecret: process.env.JWT_SECRET,
        pgArchivedColumnName: 'archived_at'
    },

    gather: {
        pgJwtTypes: `${process.env.AUTH_SCHEMA}.jwt_token`,
        installWatchFixtures: true,
    },

    grafast: {
        context(requestContext, args) {
            return authorize(requestContext, args);
        },
        explain: !live,
    },

    grafserv: {
        port: process.env.GRAPHQL_PORT,
        watch: true,
    },

    pgServices: [
        makePgService({
            connectionString: process.env.DATABASE_URL,
            superuserConnectionString: process.env.SUPERUSER_DATABASE_URL,
            schemas: [process.env.EXPOSED_SCHEMA],
            pubsub: true,
        })
    ]
};

export default preset;