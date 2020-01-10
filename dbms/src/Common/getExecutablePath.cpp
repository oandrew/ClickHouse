#include <Common/getExecutablePath.h>


#if OS_DARWIN
#include <boost/filesystem.hpp>
std::string getExecutablePath()
{
    
    boost::system::error_code ec;
    boost::filesystem::path canonical_path = boost::filesystem::canonical("/proc/self/exe", ec);

    if (ec)
        return {};
    return canonical_path.string();
}
#else
#include <filesystem>
std::string getExecutablePath()
{
    
    std::error_code ec;
    std::filesystem::path canonical_path = std::filesystem::canonical("/proc/self/exe", ec);

    if (ec)
        return {};
    return canonical_path;
}
#endif


