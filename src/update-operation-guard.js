'use strict';

// All updater entry points share progress and cache files. Reject overlapping
// requests instead of letting two transfers overwrite each other's state.
function createUpdateOperationGuard() {
  let active = false;
  return async function runUpdateOperation(operation) {
    if (active) {
      const error = new Error('Já existe uma atualização em andamento. Aguarde a conclusão.');
      error.code = 'UPDATE_BUSY';
      throw error;
    }
    active = true;
    try {
      return await operation();
    } finally {
      active = false;
    }
  };
}

module.exports = { createUpdateOperationGuard };
