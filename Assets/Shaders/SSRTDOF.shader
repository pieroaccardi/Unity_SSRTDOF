// Upgrade NOTE: replaced 'mul(UNITY_MATRIX_MVP,*)' with 'UnityObjectToClipPos(*)'

Shader "PostProcess/SSRTDOF"
{
	Properties
	{
	}
	SubShader
	{
		Tags { "RenderType"="Opaque" }
		LOD 100

		Pass  //pass 0 - write linear depth
		{

			CGPROGRAM
			#pragma vertex vert
			#pragma fragment frag
			
			#include "UnityCG.cginc"

			struct VS_INPUT
			{
				float4 Position : POSITION;
			};

			struct PS_INPUT 
			{
				float4 Position : SV_POSITION;
				float4 ViewSpacePos : TEXCOORD0;
			};

			PS_INPUT vert (VS_INPUT input)
			{
				PS_INPUT output;
				output.ViewSpacePos = mul(UNITY_MATRIX_MV, input.Position);
				output.Position = mul(UNITY_MATRIX_P, output.ViewSpacePos);
				return output;
			}
			
			float frag (PS_INPUT input) : SV_Target
			{
				float3 p = input.ViewSpacePos.xyz;
				return p.z;
			}

			ENDCG
		}
	
		Pass  //pass 1 - Ray tracing with screen space marching
		{

			CGPROGRAM
			#pragma vertex vert
			#pragma fragment frag
			#pragma target 5.0

			#include "UnityCG.cginc"

			#pragma enable_d3d11_debug_symbols

			#define MAX_DISTANCE 200
			#define MAX_STEPS 300
			#define STEP 1
			#define SPP 32
						
			sampler2D _MainTex;
			sampler2D LinearDepthSampler;
			sampler2D RandomRotations;

			float circleSamples[64];
			float4x4 frustumCorners; 
			float focalDistance;
			float aperture;
			float4x4 ProjectionMat;

			struct VS_INPUT
			{
				float4 Position : POSITION;
				half2 uv : TEXCOORD0;
				uint vertexID : SV_VertexID;
			};

			struct PS_INPUT
			{
				float4 Position : SV_POSITION;
				half2 uv : TEXCOORD0;
				float3 ViewDirection : TEXCOORD1;
			};

			PS_INPUT vert(VS_INPUT input)
			{
				PS_INPUT output;

				output.Position = UnityObjectToClipPos(input.Position);

				output.uv = MultiplyUV(UNITY_MATRIX_TEXTURE0, input.uv);

				output.ViewDirection = frustumCorners[input.vertexID].xyz;

				return output;
			}

			float DistanceSqr2D(float2 A, float2 B)
			{
				float2 d = B - A;
				return dot(d, d);
			}

			float4 frag(PS_INPUT input) : SV_Target
			{
				float3 V = normalize(input.ViewDirection);  //view direction in view space
				float3 focalPoint = focalDistance / abs(V.z) * V;

				float randomRot = tex2D(RandomRotations, input.Position / 16); 
				float cosTheta = cos(randomRot);  //i should save sin and cos directly in the texture for optimization
				float sinTheta = sin(randomRot);
				float2 rotationRow1 = float2(cosTheta, -sinTheta);
				float2 rotationRow2 = float2(sinTheta, cosTheta);
					
				float4 accumulated = float4(0, 0, 0, 1);

				for (int s = 0; s < SPP; ++s)  //4 samples for pixel
				{
					float2 hitPixel;

					float2 samp = float2(circleSamples[s * 2 + 0], circleSamples[s * 2 + 1]);
					float2 rotatedSample = float2(dot(rotationRow1, samp), dot(rotationRow2, samp));
					float3 rayOrigin = float3(rotatedSample * aperture, 0); //in view space
					float3 rayDirection = normalize(focalPoint - rayOrigin); //in view space
					float3 rayEnd = rayOrigin + rayDirection * MAX_DISTANCE; //in view space
					rayOrigin = rayOrigin + rayDirection * 0.3 / abs(rayDirection.z); //move the origin on the near plane

					//project the first and the last point
					float4 H0 = mul(ProjectionMat, float4(rayOrigin, 1));
					float4 H1 = mul(ProjectionMat, float4(rayEnd, 1));
					
					//this quantities are linear interpolable in screen space, so their first derivative is costant
					float k0 = 1.0 / H0.w;
					float k1 = 1.0 / H1.w;
					float3 Q0 = rayOrigin * k0;
					float3 Q1 = rayEnd * k1;

					//end points in screen space, not normalized but with pixel values from [0, Width][0, Height]
					float2 P0 = (H0.xy * k0 * 0.5 + 0.5) * _ScreenParams.xy;
					float2 P1 = (H1.xy * k1 * 0.5 + 0.5) * _ScreenParams.xy;

					//P1 += (DistanceSqr2D(P0, P1) < 0.0001) ? 0.01 : 0.0;
					if (DistanceSqr2D(P0, P1) < 0.0001)
					{
						float2 texcoord = P0 / _ScreenParams.xy;
						return tex2Dlod(_MainTex, float4(texcoord, 0, 0));
					}

					float2 delta = P1 - P0;

					bool permute = false;
					if (abs(delta.x) < abs(delta.y))
					{
						permute = true;
						delta = delta.yx;
						P0 = P0.yx;
						P1 = P1.yx;
					}

					float stepDir = sign(delta.x);
					float invdx = stepDir / delta.x;

					//derivative
					float3 dQ = (Q1 - Q0) * invdx;
					float dk = (k1 - k0) * invdx;
					float2 dP = float2(stepDir, delta.y * invdx);

					dP *= STEP;
					dQ *= STEP;
					dk *= STEP;

					float3 Q = Q0;
					float k = k0;
					float stepCount = 0;
					float end = P1.x * stepDir;
					float2 texcoord = float2(0, 0);
					float intersectionFound = 0;

					//ray marching
					for (float2 P = P0; ((P.x * stepDir) <= end) && (stepCount < MAX_STEPS); P += dP, Q += dQ, k += dk, stepCount += 1.0)
					{
						hitPixel = (permute ? P.yx : P);
						texcoord = hitPixel / _ScreenParams.xy;

						float sampledDepth = tex2Dlod(LinearDepthSampler, float4(texcoord, 0, 0));
						float interpolatedDepth = Q.z / k;
						if (interpolatedDepth <= sampledDepth)
						{
							intersectionFound = 1;
							break;
						}
					}

					accumulated += tex2Dlod(_MainTex, float4(texcoord, 0, 0));
				}

				accumulated /= SPP; 

				return accumulated;
			}

			ENDCG
		}
	}
}
