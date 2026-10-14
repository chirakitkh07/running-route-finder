const app = require('./app');
const PORT = process.env.PORT || 3000;
const ReportRepository = require('./repositories/reportRepository');

app.listen(PORT, () => {
    console.log(`Server is running on port ${PORT}`);
    
    // Time-based Validity (TTL) Job: Check every hour (3600000 ms)
    setInterval(async () => {
        try {
            const changes = await ReportRepository.expireOldReports(24);
            if (changes > 0) {
                console.log(`[TTL Job] Expired ${changes} old incident reports.`);
            }
        } catch (error) {
            console.error('[TTL Job] Error expiring reports:', error);
        }
    }, 60 * 60 * 1000); // 1 hour
});
