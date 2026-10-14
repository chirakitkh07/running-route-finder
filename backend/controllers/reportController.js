const ReportService = require('../services/reportService');

exports.createReport = async (req, res) => {
  try {
    const reportData = req.body;
    const newReport = await ReportService.createReport(reportData);
    res.status(201).json(newReport);
  } catch (error) {
    if (error.message.includes('Missing require fields')) {
      return res.status(400).json({ error: error.message });
    }
    res.status(500).json({ error: error.message });
  }
};

exports.getAllActiveReports = async (req, res) => {
  try {
    const reports = await ReportService.getActiveReports();
    res.status(200).json(reports);
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
};

exports.voteReport = async (req, res) => {
  try {
    const { id } = req.params;
    const { action } = req.body; // 'verify' or 'reject'
    
    const updatedReport = await ReportService.voteReport(id, action);
    res.status(200).json(updatedReport);
  } catch (error) {
    if (error.message.includes('Invalid action')) {
      return res.status(400).json({ error: error.message });
    }
    res.status(500).json({ error: error.message });
  }
};

exports.verifyReport = async (req, res) => {
  try {
    const { id } = req.params;
    const result = await ReportService.verifyReport(id);
    res.status(200).json(result);
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
};
