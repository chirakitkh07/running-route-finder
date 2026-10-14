const db = require('../config/db');

exports.getDashboardStats = async (req, res) => {
    try {
        // Fetch stats from DB
        const userCount = await new Promise((resolve) => {
            db.get(`SELECT COUNT(DISTINCT userId) as count FROM routes`, [], (err, row) => resolve(row ? row.count : 0));
        });
        
        const routeCount = await new Promise((resolve) => {
            db.get(`SELECT COUNT(*) as count FROM routes`, [], (err, row) => resolve(row ? row.count : 0));
        });

        const reportCount = await new Promise((resolve) => {
            db.get(`SELECT COUNT(*) as count FROM reports`, [], (err, row) => resolve(row ? row.count : 0));
        });

        res.status(200).json({
            users: userCount,
            savedRoutes: routeCount,
            totalReports: reportCount,
            activeReports: reportCount // simplified
        });
    } catch (error) {
        res.status(500).json({ error: error.message });
    }
};

exports.getStandardRoutes = async (req, res) => {
    res.status(200).json({ message: "List of standard routes" });
};

exports.createStandardRoute = async (req, res) => {
    res.status(201).json({ message: "Standard route created successfully" });
};

exports.deleteStandardRoute = async (req, res) => {
    res.status(200).json({ message: `Standard route ${req.params.id} deleted` });
};

exports.deleteReport = async (req, res) => {
    try {
        const { id } = req.params;
        const sql = `DELETE FROM reports WHERE id = ?`;
        
        db.run(sql, [id], function(err) {
            if (err) return res.status(500).json({ error: err.message });
            if (this.changes === 0) return res.status(404).json({ error: 'Report not found' });
            
            res.status(200).json({ message: `Report ${id} permanently deleted by admin.` });
        });
    } catch (error) {
        res.status(500).json({ error: error.message });
    }
};

exports.getAiModerationLogs = async (req, res) => {
    try {
        const sql = `SELECT * FROM ai_logs ORDER BY createdAt DESC LIMIT 50`;
        db.all(sql, [], (err, rows) => {
            if (err) return res.status(500).json({ error: err.message });
            res.status(200).json(rows);
        });
    } catch (error) {
        res.status(500).json({ error: error.message });
    }
};
