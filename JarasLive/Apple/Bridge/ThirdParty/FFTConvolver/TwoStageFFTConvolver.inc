// ==================================================================================
// Copyright (c) 2017 HiFi-LoFi
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is furnished
// to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
// FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
// COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
// IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
// WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
// ==================================================================================

#include "TwoStageFFTConvolver.h"

#include <algorithm>
#include <atomic>
#include <cmath>


namespace fftconvolver
{

namespace
{
// Hook Keys: cada instancia recebe uma posicao diferente para o trabalho da
// cauda dentro do periodo (ver _stepFinishFill/_stepFftPosition).
std::atomic<unsigned> scheduleSlots(0);
}

TwoStageFFTConvolver::TwoStageFFTConvolver() :
  _headBlockSize(0),
  _tailBlockSize(0),
  _headConvolver(),
  _tailConvolver0(),
  _tailOutput0(),
  _tailPrecalculated0(0),
  _tailConvolver(),
  _tailOutput(),
  _tailPrecalculated(0),
  _tailInput(),
  _tailInputFill(0),
  _precalculatedPos(0),
  _backgroundProcessingInput(),
  _backgroundPending(false),
  _backgroundStepsDone(0),
  _stepFinishFill(0),
  _stepFftPosition(0)
{
}


TwoStageFFTConvolver::~TwoStageFFTConvolver()
{
  reset();
}


void TwoStageFFTConvolver::reset()
{
  _headBlockSize = 0;
  _tailBlockSize = 0;
  _headConvolver.reset();
  _tailConvolver0.reset();
  _tailOutput0.clear();
  _tailPrecalculated0.clear();
  _tailConvolver.reset();
  _tailOutput.clear();
  _tailPrecalculated.clear();
  _tailInput.clear();
  _tailInputFill = 0;
  _tailInputFill = 0;
  _precalculatedPos = 0;
  _backgroundProcessingInput.clear();
  _backgroundPending = false;
  _backgroundStepsDone = 0;
}


void TwoStageFFTConvolver::clearHistory()
{
  _headConvolver.clearHistory();
  _tailConvolver0.clearHistory();
  _tailConvolver.clearHistory();
  // _tailInput e _backgroundProcessingInput sao reescritos antes de qualquer
  // leitura; os precalculados voltam a ser somados na saida e os de saida
  // viram precalculados na proxima troca.
  _tailOutput0.setZero();
  _tailPrecalculated0.setZero();
  _tailOutput.setZero();
  _tailPrecalculated.setZero();
  _tailInputFill = 0;
  _precalculatedPos = 0;
  _backgroundPending = false;
  _backgroundStepsDone = 0;
}


bool TwoStageFFTConvolver::init(size_t headBlockSize,
                                size_t tailBlockSize,
                                const Sample* ir,
                                size_t irLen)
{
  reset();

  if (headBlockSize == 0 || tailBlockSize == 0)
  {
    return false;
  }

  headBlockSize = std::max(size_t(1), headBlockSize);
  if (headBlockSize > tailBlockSize)
  {
    assert(false);
    std::swap(headBlockSize, tailBlockSize);
  }

  // Ignore zeros at the end of the impulse response because they only waste computation time
  while (irLen > 0 && ::fabs(ir[irLen-1]) < 0.000001f)
  {
    --irLen;
  }

  if (irLen == 0)
  {
    return true;
  }

  _headBlockSize = NextPowerOf2(headBlockSize);
  _tailBlockSize = NextPowerOf2(tailBlockSize);

  const size_t headIrLen = std::min(irLen, _tailBlockSize);
  _headConvolver.init(_headBlockSize, ir, headIrLen);

  if (irLen > _tailBlockSize)
  {
    const size_t conv1IrLen = std::min(irLen-_tailBlockSize, _tailBlockSize);
    _tailConvolver0.init(_headBlockSize, ir+_tailBlockSize, conv1IrLen);
    _tailOutput0.resize(_tailBlockSize);
    _tailPrecalculated0.resize(_tailBlockSize);
  }

  if (irLen > 2 * _tailBlockSize)
  {
    const size_t tailIrLen = irLen - (2*_tailBlockSize);
    _tailConvolver.init(_tailBlockSize, ir+(2*_tailBlockSize), tailIrLen);
    _tailOutput.resize(_tailBlockSize);
    _tailPrecalculated.resize(_tailBlockSize);
    _backgroundProcessingInput.resize(_tailBlockSize);

    // Hook Keys: termina a cauda entre ~53% e 100% do periodo e faz a FFT
    // em pontos diferentes da soma, conforme a instancia.
    const unsigned slot = scheduleSlots.fetch_add(1, std::memory_order_relaxed) % 16u;
    const size_t headBlocks = _tailBlockSize / _headBlockSize;
    const size_t finishBlocks = std::max<size_t>(1,
        (headBlocks * (16 + ((slot * 7u) % 16u + 1u)) + 31) / 32);
    _stepFinishFill = std::min(_tailBlockSize, finishBlocks * _headBlockSize);
    const size_t segments = _tailConvolver.stepCount() > 0 ? _tailConvolver.stepCount() - 1 : 0;
    _stepFftPosition = segments > 0 ? ((slot * 5u) % 16u) * (segments - 1) / 16u : 0;
  }

  if (_tailPrecalculated0.size() > 0 || _tailPrecalculated.size() > 0)
  {
    _tailInput.resize(_tailBlockSize);
  }
  _tailInputFill = 0;
  _precalculatedPos = 0;

  return true;
}


void TwoStageFFTConvolver::process(const Sample* input, Sample* output, size_t len)
{
  // Head
  _headConvolver.process(input, output, len);

  // Tail
  if (_tailInput.size() > 0)
  {
    size_t processed = 0;
    while (processed < len)
    {
      const size_t remaining = len - processed;
      const size_t processing = std::min(remaining, _headBlockSize - (_tailInputFill % _headBlockSize));
      assert(_tailInputFill + processing <= _tailBlockSize);

      // Sum head and tail
      const size_t sumBegin = processed;
      const size_t sumEnd = processed + processing;
      {
        // Sum: 1st tail block
        if (_tailPrecalculated0.size() > 0)
        {
          size_t precalculatedPos = _precalculatedPos;
          for (size_t i=sumBegin; i<sumEnd; ++i)
          {
            output[i] += _tailPrecalculated0[precalculatedPos];
            ++precalculatedPos;
          }
        }

        // Sum: 2nd-Nth tail block
        if (_tailPrecalculated.size() > 0)
        {
          size_t precalculatedPos = _precalculatedPos;
          for (size_t i=sumBegin; i<sumEnd; ++i)
          {
            output[i] += _tailPrecalculated[precalculatedPos];
            ++precalculatedPos;
          }
        }

        _precalculatedPos += processing;
      }

      // Fill input buffer for tail convolution
      ::memcpy(_tailInput.data()+_tailInputFill, input+processed, processing * sizeof(Sample));
      _tailInputFill += processing;
      assert(_tailInputFill <= _tailBlockSize);

      // Convolution: 1st tail block
      if (_tailPrecalculated0.size() > 0 && _tailInputFill % _headBlockSize == 0)
      {
        assert(_tailInputFill >= _headBlockSize);
        const size_t blockOffset = _tailInputFill - _headBlockSize;
        _tailConvolver0.process(_tailInput.data()+blockOffset, _tailOutput0.data()+blockOffset, _headBlockSize);
        if (_tailInputFill == _tailBlockSize)
        {
          SampleBuffer::Swap(_tailPrecalculated0, _tailOutput0);
        }
      }

      // Hook Keys: avanca a cauda do periodo anterior na proporcao do periodo
      // atual. No fechamento do periodo o alvo e o total: nada fica pendente.
      if (_backgroundPending)
      {
        advanceBackgroundProcessing();
      }

      // Convolution: 2nd-Nth tail block (might be done in some background thread)
      if (_tailPrecalculated.size() > 0 &&
          _tailInputFill == _tailBlockSize &&
          _backgroundProcessingInput.size() == _tailBlockSize &&
          _tailOutput.size() == _tailBlockSize)
      {
        waitForBackgroundProcessing();
        SampleBuffer::Swap(_tailPrecalculated, _tailOutput);
        _backgroundProcessingInput.copyFrom(_tailInput);
        startBackgroundProcessing();
      }

      if (_tailInputFill == _tailBlockSize)
      {
        _tailInputFill = 0;
        _precalculatedPos = 0;
      }

      processed += processing;
    }
  }
}


void TwoStageFFTConvolver::startBackgroundProcessing()
{
  // Hook Keys: so registra o bloco; o calculo anda em advanceBackgroundProcessing().
  _tailConvolver.beginSteppedBlock(_backgroundProcessingInput.data(), _stepFftPosition);
  _backgroundPending = true;
  _backgroundStepsDone = 0;
}


void TwoStageFFTConvolver::waitForBackgroundProcessing()
{
  doBackgroundProcessing();
}


void TwoStageFFTConvolver::doBackgroundProcessing()
{
  // Termina o que ainda faltar do bloco pendente (normalmente nada).
  if (!_backgroundPending)
  {
    return;
  }
  _tailConvolver.advanceSteppedBlock(static_cast<size_t>(-1), _tailOutput.data());
  _backgroundPending = false;
}


void TwoStageFFTConvolver::advanceBackgroundProcessing()
{
  const size_t total = _tailConvolver.stepCount();
  const size_t finish = _stepFinishFill > 0 ? _stepFinishFill : _tailBlockSize;
  const size_t fill = std::min(_tailInputFill, finish);
  const size_t target = (total * fill + finish - 1) / finish;
  if (target <= _backgroundStepsDone)
  {
    return;
  }
  if (_tailConvolver.advanceSteppedBlock(target - _backgroundStepsDone, _tailOutput.data()))
  {
    _backgroundPending = false;
  }
  _backgroundStepsDone = target;
}

} // End of namespace fftconvolver
