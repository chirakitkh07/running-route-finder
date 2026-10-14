const SimulationService = require('../services/simulationService');

exports.simulatePreRun = async (req, res) => {
  try {
    const { lat, lng } = req.query;
    
    const simulationResult = await SimulationService.simulatePreRun(
      parseFloat(lat), 
      parseFloat(lng)
    );

    res.status(200).json(simulationResult);

  } catch (error) {
    if (error.message.includes('Missing lat or lng')) {
      return res.status(400).json({ error: error.message });
    }
    res.status(500).json({ error: error.message });
  }
};
