#pragma once
#include "Common.h"
namespace catlive {
// AIFC fl32 preserves the same float headroom as WAV32 and AVAudioFile on Mac.
// JUCE's AIFF writer silently writes signed PCM even when float is requested.
class AiffFloatWriter final {
    FileOutputStream output;int channels;int64 remaining;MemoryBlock interleaved;
public:
    AiffFloatWriter(const File &file,double rate,int count,int64 frames):output(file),channels(count),remaining(frames){
        if(!output.openedOk()||frames<0||count<1||count>2||frames*count*4>0xffffffffLL-72)
            throw std::runtime_error("Não foi possível criar o AIFF. Cada arquivo deve ter menos de 4 GB.");
        const auto bytes=(uint32)(frames*count*4);
        output.write("FORM",4);output.writeIntBigEndian((int)(bytes+64));output.write("AIFC",4);
        output.write("FVER",4);output.writeIntBigEndian(4);output.writeIntBigEndian((int)0xa2805140u);
        output.write("COMM",4);output.writeIntBigEndian(24);output.writeShortBigEndian((short)count);
        output.writeIntBigEndian((int)frames);output.writeShortBigEndian(32);
        int exponent=0;const double fraction=std::frexp(rate,&exponent);
        output.writeShortBigEndian((short)(exponent-1+16383));
        const auto significand=(uint64)std::ldexp(fraction,64);
        output.writeIntBigEndian((int)(significand>>32));output.writeIntBigEndian((int)significand);
        output.write("fl32",4);output.writeShortBigEndian(0); // empty, padded Pascal name
        output.write("SSND",4);output.writeIntBigEndian((int)(bytes+8));output.writeIntBigEndian(0);output.writeIntBigEndian(0);
        if(output.getStatus().failed())throw std::runtime_error("Falha ao gravar o cabeçalho AIFF.");
    }
    void write(const AudioBuffer<float> &buffer,int frames){
        if(frames<0||frames>remaining)throw std::runtime_error("Duração inválida na gravação AIFF.");
        interleaved.setSize((size_t)frames*channels*4,false);auto *bytes=static_cast<uint8*>(interleaved.getData());
        for(int n=0;n<frames;++n)for(int ch=0;ch<channels;++ch){
            const float value=buffer.getSample(ch,n);uint32 bits;std::memcpy(&bits,&value,sizeof(bits));
            *bytes++=(uint8)(bits>>24);*bytes++=(uint8)(bits>>16);*bytes++=(uint8)(bits>>8);*bytes++=(uint8)bits;
        }
        if(!output.write(interleaved.getData(),interleaved.getSize()))throw std::runtime_error("Falha ao gravar o áudio AIFF. Confira o espaço disponível no disco.");
        remaining-=frames;
    }
    void finish(){output.flush();if(remaining!=0||output.getStatus().failed())throw std::runtime_error("Falha ao concluir o áudio AIFF.");}
};
}
