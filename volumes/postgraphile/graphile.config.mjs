import { PostGraphileAmberPreset } from "postgraphile/presets/amber";
import { makePgService } from "@dataplan/pg/adaptors/pg";

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

/** @type {GraphileConfig.Preset} */
const preset = {
    extends: [PostGraphileAmberPreset],
    gather: {
        installWatchFixtures: true,
    },
    grafast: {
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
            schemas: [process.env.POSTGRAPHILE_SCHEMA],
            pubsub: true,
        })
    ]
};

export default preset;