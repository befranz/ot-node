const { execSync } = require('child_process');
const request = require('request');
const fs = require('fs');
const Zip = require('machinepack-zip');

// function execSync(command, verbose = false) {
//     return new Promise((resolve, reject) => {
//         exec(command, (err, stdout, stderr) => {
//             if (err) {
//                 console.log(err);
//                 reject(err);
//             }
//
//             if (verbose) {
//                 resolve({ stdout, stderr });
//             } else {
//                 resolve();
//             }
//         });
//     });
// }

process.once('message', async ([options]) => {
    const filename = `https://github.com/${options.autoUpdater.repo}/archive/${options.autoUpdater.branch}.zip`;
    console.log(`Downloading update: ${filename} ...`);
    const response = await request(filename);
    const filestream = fs.createWriteStream('update.zip');
    response.pipe(filestream);
    console.log(options.appDataPath);

    filestream.on('finish', () => {
        console.log('Download complete');
        console.log('Extracting update...');

        Zip.unzip({
            source: 'update.zip',
            destination: '..',
        }).exec({
            error(err) {
                console.log(err);
            },

            success() {
                try {
                    console.log('Update extraction complete');
                    console.log(`Moving update to directory ${options.version}...`);

                    console.log('Cleaning update destination directory');
                    execSync(`rm -rf ../${options.version}`);

                    let extractedFileName = options.autoUpdater.branch;
                    console.log(extractedFileName);
                    extractedFileName = `ot-node-${extractedFileName.replace('/', '-')}`;
                    console.log(`mv ../${extractedFileName} ../${options.version}`);
                    execSync(`mv ../${extractedFileName} ../${options.version}`);

                    console.log(`Update has been moved to directory ${options.version}`);
                    console.log('Migrating node modules...');

                    console.log(`cp -r ./node_modules ../${options.version}/`);
                    execSync(`cp -r ./node_modules ../${options.version}/`);
                    console.log('Node modules migrated');
                    console.log('Installing new node modules');

                    console.log(`cd ../${options.version} && npm install`);
                    execSync(`cd ../${options.version} && npm install`);
                    console.log('npm modules have been installed');
                    console.log('Migrating node configuration');

                    console.log(`cp -r ${options.appDataPath}/ /ot-node/${options.version}/`);
                    execSync(`cp -r ${options.appDataPath} /ot-node/${options.version}/`);
                    console.log('Configuration migration complete');

                    console.log('Processing database migrations');
                    console.log(`/ot-node/${options.version}/node_modules/.bin/sequelize --config=/ot-node/${options.version}/config/sequelizeConfig.js db:migrate`);
                    execSync(`/ot-node/${options.version}/node_modules/.bin/sequelize --config=/ot-node/${options.version}/config/sequelizeConfig.js db:migrate`);
                    console.log(`Running seeders for '${options.appDataPath}'...`);
                    console.log(`/ot-node/${options.version}/node_modules/.bin/sequelize --config=/ot-node/${options.version}/config/sequelizeConfig.js db:seed:all`);
                    execSync(`/ot-node/${options.version}/node_modules/.bin/sequelize --config=/ot-node/${options.version}/config/sequelizeConfig.js db:seed:all`);
                    console.log('Switching node version');
                    process.send('complete');
                    console.log(`ln -sfn /ot-node/${options.version}/ /ot-node/current`);
                    execSync(`ln -sfn /ot-node/${options.version}/ /ot-node/current`);
                    process.exit(0);
                } catch (err) {
                    // TODO: Rollback
                    console.log(err);
                }
            },
        });
    });
});
