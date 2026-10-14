const db = require('../config/db');

class AiModerationService {
  /**
   * Check content for spam/toxicity and log the result
   */
  async moderateReport(reportId, content) {
    if (!content) return { status: 'passed' };

    // Simple mocked AI logic (Keyword-based for simulation)
    const badWords = ['fake', 'spam', 'idiot', 'stupid', 'test1234'];
    const lowerContent = content.toLowerCase();
    
    let isFlagged = false;
    let confidence = 0.5 + (Math.random() * 0.4); // Random confidence between 50% and 90%
    
    for (const word of badWords) {
      if (lowerContent.includes(word)) {
        isFlagged = true;
        confidence = 0.85 + (Math.random() * 0.14); // 85% to 99%
        break;
      }
    }

    const action = isFlagged ? 'flagged' : 'passed';

    // Log to DB
    return new Promise((resolve, reject) => {
      const sql = `INSERT INTO ai_logs (reportId, action, content, confidence) VALUES (?, ?, ?, ?)`;
      db.run(sql, [reportId, action, content, confidence], function(err) {
        if (err) console.error('AI Log error:', err);
        
        // If flagged by AI, we could also automatically reject the report or lower its votes
        // For now, we just return the analysis result
        resolve({ action, confidence });
      });
    });
  }
}

module.exports = new AiModerationService();
