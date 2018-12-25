const Command = require('../command');
const Utilities = require('../../Utilities');
const Models = require('../../../models/index');

const { Op } = Models.Sequelize;

/**
 * Repeatable command that checks whether offer is ready or not
 */
class DcOfferFinalizedCommand extends Command {
    constructor(ctx) {
        super(ctx);
        this.logger = ctx.logger;
        this.challengeService = ctx.challengeService;
        this.replicationService = ctx.replicationService;
    }

    /**
     * Executes command and produces one or more events
     * @param command
     */
    async execute(command) {
        const { offerId } = command.data;

        const events = await Models.events.findAll({
            where: {
                event: 'OfferFinalized',
                finished: 0,
            },
        });
        if (events) {
            const event = events.find((e) => {
                const {
                    offerId: eventOfferId,
                } = JSON.parse(e.data);
                return Utilities.compareHexStrings(offerId, eventOfferId);
            });
            if (event) {
                event.finished = true;
                await event.save({ fields: ['finished'] });

                this.logger.important(`Offer ${offerId} finalized`);

                const offer = await Models.offers.findOne({ where: { offer_id: offerId } });
                offer.status = 'FINALIZED';
                offer.message = 'Offer has been finalized. Offer is now active.';
                await offer.save({ fields: ['status', 'message'] });

                const {
                    holder1,
                    holder2,
                    holder3,
                } = JSON.parse(event.data);

                const holders = [holder1, holder2, holder3].map(h => Utilities.normalizeHex(h));
                await Models.replicated_data.update(
                    {
                        status: 'HOLDING',
                    },
                    {
                        where: {
                            offer_id: offer.offer_id,
                            dh_identity: {
                                [Op.in]: holders,
                            },
                        },
                    },
                );

                const scheduledTime = (offer.holding_time_in_minutes * 60 * 1000) + (60 * 1000);
                return {
                    commands: [
                        {
                            name: 'dcOfferCleanupCommand',
                            data: {
                                offerId,
                            },
                            delay: scheduledTime,
                        },
                    ],
                };
            }
        }
        return Command.repeat();
    }

    /**
     * Execute strategy when event is too late
     * @param command
     */
    async expired(command) {
        const { offerId } = command.data;
        this.logger.notify(`Offer ${offerId} has not been finalized.`);

        const offer = await Models.offers.findOne({ where: { id: offerId } });
        offer.status = 'FAILED';
        offer.message = `Offer for ${offerId} has not been finalized.`;
        await offer.save({ fields: ['status', 'message'] });

        await this.replicationService.cleanup(offer.id);
        return Command.empty();
    }

    /**
     * Builds default AddCommand
     * @param map
     * @returns {{add, data: *, delay: *, deadline: *}}
     */
    default(map) {
        const command = {
            name: 'dcOfferFinalizedCommand',
            delay: 0,
            period: 5000,
            deadline_at: Date.now() + (5 * 60 * 1000),
            transactional: false,
        };
        Object.assign(command, map);
        return command;
    }
}

module.exports = DcOfferFinalizedCommand;
