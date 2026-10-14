const { db } = require('../firebase');

const reportsCollection = db.collection('reports');

class ReportModel {
  // Create a new hazard report (pin)
  static async createReport(reportData) {
    try {
      const docRef = await reportsCollection.add({
        ...reportData,
        status: 'active', // active, rejected, expired
        verifiedCount: 0,
        rejectedCount: 0,
        createdAt: new Date().toISOString()
      });
      return { id: docRef.id, ...reportData };
    } catch (error) {
      throw new Error('Error creating report: ' + error.message);
    }
  }

  // Get all active reports
  static async getActiveReports() {
    try {
      const snapshot = await reportsCollection.where('status', '==', 'active').get();
      if (snapshot.empty) return [];
      
      const reports = [];
      snapshot.forEach(doc => reports.push({ id: doc.id, ...doc.data() }));
      return reports;
    } catch (error) {
      throw new Error('Error fetching reports: ' + error.message);
    }
  }

  // Update report (e.g. upvote/downvote verification)
  static async updateReportVotes(reportId, type) {
    try {
      const docRef = reportsCollection.doc(reportId);
      const doc = await docRef.get();
      if (!doc.exists) throw new Error('Report not found');
      
      const data = doc.data();
      const updates = {};
      
      if (type === 'verify') updates.verifiedCount = (data.verifiedCount || 0) + 1;
      if (type === 'reject') updates.rejectedCount = (data.rejectedCount || 0) + 1;

      // Auto-update status if rejected too many times (AI Mode/Rules Engine part)
      if (updates.rejectedCount >= 5) updates.status = 'rejected';

      await docRef.update(updates);
      return { id: reportId, ...data, ...updates };
    } catch (error) {
      throw new Error('Error updating report: ' + error.message);
    }
  }
}

module.exports = ReportModel;
