const BN = require('bn.js');
const utilities = require('../Utilities');
const models = require('../../models');
const sleep = require('sleep-async')().Promise;

const MAX_TOKEN_AMOUNT = 1000000;

/**
 * Runs all pending payout commands
 */
class M2WithdrawAllMigration {
    constructor({
        logger, blockchain, config, web3, commandExecutor,
    }) {
        this.logger = logger;
        this.config = config;
        this.web3 = web3;
        this.blockchain = blockchain;
        this.commandExecutor = commandExecutor;
    }

    /**
     * Run migration
     */
    async run() {
        const mTRAC = this.web3.utils.toWei(MAX_TOKEN_AMOUNT.toString(), 'ether');

        await this.blockchain.startTokenWithdrawal(
            utilities.normalizeHex(this.config.erc725Identity),
            new BN(mTRAC, 10),
        );

        let started = false;
        let waitInSeconds = null;
        let amountToWithdraw = null;
        const until = Date.now() + 60000;
        while (Date.now() < until) {
            // eslint-disable-next-line
            const events =await models.events.findAll({
                where: {
                    event: 'WithdrawalInitiated',
                    finished: 0,
                },
            });

            if (events) {
                const event = events.find((e) => {
                    const {
                        profile: eventProfile,
                    } = JSON.parse(e.data);
                    return eventProfile.toLowerCase()
                        .includes(this.config.erc725Identity.toLowerCase());
                });
                if (event) {
                    const {
                        amount: eAmount,
                        withdrawalDelayInSeconds: eWithdrawalDelayInSeconds,
                    } = JSON.parse(event.data);
                    this.logger.important(`Token withdrawal for amount ${eAmount} initiated.`);
                    started = true;
                    waitInSeconds = eWithdrawalDelayInSeconds;
                    amountToWithdraw = eAmount;
                    break;
                }
            }

            // eslint-disable-next-line
            await sleep.sleep(1000);
        }

        if (started) {
            waitInSeconds += 30;
            this.logger.info(`Waiting for ${waitInSeconds} seconds... `);
            await sleep.sleep(waitInSeconds * 1000);

            const blockchainIdentity = utilities.normalizeHex(this.config.erc725Identity);
            await this.blockchain.withdrawTokens(blockchainIdentity);
            this.logger.important(`Token withdrawal for amount ${mTRAC} completed.`);
        } else {
            throw new Error('Failed to withdraw amounts');
        }
    }
}

module.exports = M2WithdrawAllMigration;
