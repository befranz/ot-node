
module.exports = (sequelize, DataTypes) => {
    var data_info = sequelize.define('data_info', {
        data_set_id: DataTypes.STRING,
        data_provider_wallet: DataTypes.STRING(42),
        total_documents: DataTypes.INTEGER,
        root_hash: DataTypes.STRING(40),
        import_timestamp: DataTypes.DATE,
        data_size: DataTypes.INTEGER,
        origin: DataTypes.STRING,
    }, {
        tableName: 'data_info',
    });
    data_info.associate = function (models) {
    // associations can be defined here
    };
    return data_info;
};
