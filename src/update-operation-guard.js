'use strict';

// All updater entry points share progress and cache files. Reject overlapping
// requests instead of letting two transfers overwrite each other's state.
function createUpdateOperationGuard() {
  let active = false;
  return async function runUpdateOperation(operation) {
    if (active) {
      throw new Error('Já existe uma atualização em andamento. Aguarde a conclusão.');
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
