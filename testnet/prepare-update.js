const { execSync } = require('child_process');
const request = require('request');
const fs = require('fs');
const Zip = require('machinepack-zip');
const path = require('path');
const tmpdir = require('os').tmpdir();
const uuidv4 = require('uuid/v4');
const semver = require('semver');

const logger = require('../modules/logger');

process.on('unhandledRejection', (reason, p) => {
    logger.error(`Update preparation failed.\n${reason.stack}`);
    process.exit(-2);
});

process.on('uncaughtException', (err) => {
    logger.error(`Update preparation failed: ${err}.\n${err.stack}`);
    process.exit(-1);
});

process.once('SIGTERM', () => process.exit(0));

process.once('message', async (options) => {
    /*
                const options = {
                appDataPath: config.appDataPath,
                version: remoteVersion,
                archiveUrl: config.archiveUrl,
                destinationBaseDir: '/ot-node/',
            };
     */
    const { archiveUrl, destinationBaseDir } = options;
    const localUpdateFilepath = path.join(tmpdir, 'update.zip');
    const localExtractionPath = path.join(tmpdir, uuidv4());

    fs.mkdirSync(localExtractionPath);

    logger.info(`Downloading update: ${archiveUrl}...`);
    const requestArchive = await request(archiveUrl);
    const filestream = fs.createWriteStream(localUpdateFilepath);
    requestArchive.pipe(filestream);

    filestream.on('finish', () => {
        logger.info('Download complete');
        logger.info('Extracting update...');

        Zip.unzip({
            source: localUpdateFilepath,
            destination: localExtractionPath,
        }).exec({
            error(err) {
                logger.error(err);
                process.exit(1);
            },

            success() {
                try {
                    logger.info('Update extraction completed');

                    // Should only be one dir in extraction dir.
                    const otNodeExtractionPath =
                        path.join(localExtractionPath, fs.readdirSync(localExtractionPath)[0]);

                    // Gather the info about downloaded version.
                    const pJson = JSON.parse(fs.readFileSync(path.join(otNodeExtractionPath, 'package.json'), 'utf8'));

                    if (!semver.valid(pJson.version)) {
                        throw Error(`Invalid version '${pJson.version}'.`);
                    }

                    logger.info(`Downloaded ${pJson.version} version.`);
                    logger.info('Cleaning update destination directory');
                    const installDir = path.join(destinationBaseDir, pJson.version);
                    execSync(`rm -rf ${installDir}`);

                    execSync(`mv ${otNodeExtractionPath} ${installDir}`);

                    logger.info(`Update has been moved to directory ${installDir}`);
                    logger.info('Installing node modules...');

                    execSync('npm install', { cwd: installDir });
                    logger.info('Node modules installed');
                    process.send({
                        status: 'completed',
                        installDir,
                        version: pJson.version,
                    });
                    process.exit(0);
                } catch (err) {
                    logger.error(`Update failed. ${err}. ${err.stack}`);
                    logger.error(err);
                    process.exit(-2);
                }
            },
        });
    });
});