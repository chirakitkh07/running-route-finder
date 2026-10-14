const ReportRepository = require('../repositories/reportRepository');
const AiModerationService = require('./aiModerationService');

class ReportService {
  /**
   * Submit a new report and perform any business logic
   */
  async createReport(reportData) {
    // Business logic: e.g. validate type, lat, lng
    if (!reportData.lat || !reportData.lng || !reportData.type) {
      throw new Error('Missing require fields: lat, lng, or type');
    }

    const newReport = await ReportRepository.createReport(reportData);
    
    // Call AI Moderation asynchronously (don't block the response)
    if (newReport && newReport.description) {
      AiModerationService.moderateReport(newReport.id, newReport.description).then(aiResult => {
        // If AI is highly confident it's spam, we can auto-reject it
        if (aiResult.action === 'flagged' && aiResult.confidence > 0.90) {
           ReportRepository.updateReportStatus(newReport.id); // Auto resolve/hide
        }
      });
    }

    return newReport;
  }

  /**
   * Retrieve active reports
   */
  async getActiveReports() {
    return await ReportRepository.getActiveReports();
  }

  /**
   * User votes to verify or reject
   */
  async voteReport(id, action) {
    if (action !== 'verify' && action !== 'reject') {
      throw new Error('Invalid action, use "verify" or "reject"');
    }

    // Process vote
    const updatedReport = await ReportRepository.updateReportVotes(id, action);
    
    // Business logic: if it gets too many downvotes, we could automatically resolve it
    if (updatedReport && updatedReport.votes < -3) {
      await ReportRepository.updateReportStatus(id);
      updatedReport.status = 'resolved';
    }

    return updatedReport;
  }

  /**
   * Verify a report by combining community votes and AI moderation logs.
   * Returns an object { verified: boolean, score: number, reason: string }
   */
  async verifyReport(id) {
    const report = await ReportRepository.getReportById(id);
    if (!report) throw new Error('Report not found');

    // fetch latest AI analysis for this report (if any)
    const aiLogs = await ReportRepository.getAiLogs(id);
    const latestAi = Array.isArray(aiLogs) && aiLogs.length ? aiLogs[0] : null;

    // Simple rules:
    // - If community votes >= 3 -> verified
    // - If AI flagged with high confidence (>0.90) -> not verified
    // - Otherwise compute a score from votes and AI confidence
    const votes = typeof report.votes === 'number' ? report.votes : 0;
    if (votes >= 3) return { verified: true, score: 1.0, reason: 'community' };

    if (latestAi && latestAi.action === 'flagged' && latestAi.confidence > 0.9) {
      return { verified: false, score: 0.0, reason: 'ai_flagged' };
    }

    // Normalize votes to [0,1] assuming -5..+5 typical range
    const votesScore = Math.max(0, Math.min(1, (votes + 5) / 10));
    let aiScore = 0.5;
    if (latestAi && typeof latestAi.confidence === 'number') {
      aiScore = latestAi.action === 'passed' ? latestAi.confidence : (1 - latestAi.confidence);
    }

    const score = Math.round(((0.6 * votesScore) + (0.4 * aiScore)) * 100) / 100;
    const verified = score >= 0.6;
    const reason = verified ? 'threshold' : 'insufficient_evidence';

    return { verified, score, reason, votes, ai: latestAi };
  }
}

module.exports = new ReportService();
