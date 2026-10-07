#define MINIAUDIO_IMPLEMENTATION
#define MA_NO_DEVICE_IO
#define MA_NO_DECODING
#define MA_NO_ENCODING
#define MA_NO_RESOURCE_MANAGER
#define MA_NO_NODE_GRAPH
#define MA_NO_ENGINE
#include "miniaudio.h"
#include <cmath>
#include <cstdio>
#include <vector>
int main(){
    unsigned failures=0;
    for(unsigned channels:{1u,2u}){
        unsigned sourceRate=channels==2?44100:48000,destinationRate=channels==2?48000:44100,outputChannels=3-channels;
        auto config=ma_data_converter_config_init(ma_format_f32,ma_format_f32,channels,outputChannels,sourceRate,destinationRate);
        ma_data_converter converter{};if(ma_data_converter_init(&config,nullptr,&converter)!=MA_SUCCESS)return 1;
        std::vector<float> source(sourceRate*channels),output((destinationRate+200)*outputChannels);
        for(unsigned i=0;i<sourceRate;++i)for(unsigned j=0;j<channels;++j)source[i*channels+j]=.1f*std::sin(6.28318530718*1000*i/sourceRate);
        ma_uint64 in=sourceRate,out=destinationRate+200;
        if(ma_data_converter_process_pcm_frames(&converter,source.data(),&in,output.data(),&out)!=MA_SUCCESS||out<destinationRate-100||out>destinationRate+100)++failures;
        for(unsigned i=0;i<out;++i){if(!std::isfinite(output[i*outputChannels]))++failures;if(outputChannels==2&&output[i*2]!=output[i*2+1])++failures;}
        std::printf("Resampler %u Hz/%u channels -> %u Hz/%u channels, frames=%llu\n",sourceRate,channels,destinationRate,outputChannels,(unsigned long long)out);
        ma_data_converter_uninit(&converter,nullptr);
    }
    std::printf("resampler failures=%u\n",failures);return failures?1:0;
}
